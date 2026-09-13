#include "gns_shim.h"

#include <cstring>
#include <deque>
#include <mutex>
#include <string>

#include <steam/isteamnetworkingutils.h>
#include <steam/steamnetworkingsockets.h>

namespace {

ISteamNetworkingSockets *sockets = nullptr;
std::deque<zgns_event_t> events;
std::mutex events_mutex;

SteamNetworkingIPAddr to_native(const zgns_address_t &address)
{
    SteamNetworkingIPAddr native;
    native.SetIPv6(address.ip, address.port);
    return native;
}

zgns_address_t from_native(const SteamNetworkingIPAddr &address)
{
    zgns_address_t result;
    std::memcpy(result.ip, address.m_ipv6, sizeof(result.ip));
    result.port = address.m_port;
    return result;
}

void connection_status_changed(SteamNetConnectionStatusChangedCallback_t *info)
{
    zgns_event_t event = {};
    event.connection = info->m_hConn;
    event.listen_socket = info->m_info.m_hListenSocket;
    event.old_state = static_cast<int32_t>(info->m_eOldState);
    event.state = static_cast<int32_t>(info->m_info.m_eState);
    event.end_reason = info->m_info.m_eEndReason;
    std::strncpy(
        event.end_debug,
        info->m_info.m_szEndDebug,
        sizeof(event.end_debug) - 1
    );

    std::lock_guard<std::mutex> lock(events_mutex);
    events.push_back(event);
}

SteamNetworkingConfigValue_t status_callback_option()
{
    SteamNetworkingConfigValue_t option;
    option.SetPtr(
        k_ESteamNetworkingConfig_Callback_ConnectionStatusChanged,
        reinterpret_cast<void *>(connection_status_changed)
    );
    return option;
}

zgns_result_t map_result(EResult result)
{
    switch (result) {
        case k_EResultOK:
            return ZGNS_OK;
        case k_EResultNoConnection:
        case k_EResultInvalidParam:
            return ZGNS_INVALID_HANDLE;
        case k_EResultInvalidState:
            return ZGNS_INVALID_STATE;
        case k_EResultLimitExceeded:
            return ZGNS_SEND_QUEUE_FULL;
        case k_EResultIgnored:
            return ZGNS_MESSAGE_DROPPED;
        default:
            return ZGNS_FAILED;
    }
}

int receive_message(SteamNetworkingMessage_t *message, zgns_message_t *out)
{
    if (message == nullptr || out == nullptr)
        return -1;

    out->data = message->m_pData;
    out->size = static_cast<uint32_t>(message->m_cbSize);
    out->connection = message->m_conn;
    out->connection_user_data = message->m_nConnUserData;
    out->received_at = message->m_usecTimeReceived;
    out->number = message->m_nMessageNumber;
    out->flags = static_cast<uint32_t>(message->m_nFlags);
    out->internal = message;
    return 1;
}

} // namespace

bool zgns_init(char *error_buffer, size_t error_buffer_size)
{
    if (sockets != nullptr)
        return true;

    SteamDatagramErrMsg error;
    if (!GameNetworkingSockets_Init(nullptr, error)) {
        if (error_buffer != nullptr && error_buffer_size > 0) {
            std::strncpy(error_buffer, error, error_buffer_size - 1);
            error_buffer[error_buffer_size - 1] = '\0';
        }
        return false;
    }

    sockets = SteamNetworkingSockets();
    if (sockets == nullptr) {
        if (error_buffer != nullptr && error_buffer_size > 0) {
            const char message[] = "SteamNetworkingSockets() returned null";
            std::strncpy(error_buffer, message, error_buffer_size - 1);
            error_buffer[error_buffer_size - 1] = '\0';
        }
        GameNetworkingSockets_Kill();
        return false;
    }

    if (error_buffer != nullptr && error_buffer_size > 0)
        error_buffer[0] = '\0';
    return true;
}

void zgns_kill(void)
{
    if (sockets == nullptr)
        return;

    {
        std::lock_guard<std::mutex> lock(events_mutex);
        events.clear();
    }
    sockets = nullptr;
    GameNetworkingSockets_Kill();
}

bool zgns_address_parse(
    const char *text,
    size_t text_len,
    zgns_address_t *out
)
{
    if (text == nullptr || out == nullptr ||
        std::memchr(text, '\0', text_len) != nullptr)
        return false;

    const std::string terminated(text, text_len);
    SteamNetworkingIPAddr address;
    if (!address.ParseString(terminated.c_str()))
        return false;

    *out = from_native(address);
    return true;
}

size_t zgns_address_format(
    const zgns_address_t *address,
    char *buffer,
    size_t buffer_size
)
{
    if (address == nullptr)
        return 0;

    char text[SteamNetworkingIPAddr::k_cchMaxString];
    to_native(*address).ToString(text, sizeof(text), true);
    const size_t length = std::strlen(text);
    if (buffer != nullptr && buffer_size > length)
        std::memcpy(buffer, text, length + 1);
    return length;
}

void zgns_address_any(uint16_t port, zgns_address_t *out)
{
    if (out == nullptr)
        return;
    std::memset(out->ip, 0, sizeof(out->ip));
    out->port = port;
}

void zgns_address_ipv4(
    uint8_t a,
    uint8_t b,
    uint8_t c,
    uint8_t d,
    uint16_t port,
    zgns_address_t *out
)
{
    if (out == nullptr)
        return;

    SteamNetworkingIPAddr address;
    const uint32_t ip = (static_cast<uint32_t>(a) << 24) |
        (static_cast<uint32_t>(b) << 16) |
        (static_cast<uint32_t>(c) << 8) |
        static_cast<uint32_t>(d);
    address.SetIPv4(ip, port);
    *out = from_native(address);
}

zgns_result_t zgns_listen(
    const zgns_address_t *address,
    zgns_listener_t *out
)
{
    if (sockets == nullptr)
        return ZGNS_NOT_INITIALIZED;
    if (address == nullptr || out == nullptr)
        return ZGNS_INVALID_ADDRESS;

    SteamNetworkingConfigValue_t option = status_callback_option();
    const HSteamListenSocket socket = sockets->CreateListenSocketIP(
        to_native(*address), 1, &option
    );
    if (socket == k_HSteamListenSocket_Invalid)
        return ZGNS_FAILED;

    const HSteamNetPollGroup poll_group = sockets->CreatePollGroup();
    if (poll_group == k_HSteamNetPollGroup_Invalid) {
        sockets->CloseListenSocket(socket);
        return ZGNS_FAILED;
    }

    out->socket = socket;
    out->poll_group = poll_group;
    return ZGNS_OK;
}

zgns_result_t zgns_connect(
    const zgns_address_t *address,
    zgns_connection_t *out
)
{
    if (sockets == nullptr)
        return ZGNS_NOT_INITIALIZED;
    if (address == nullptr || out == nullptr)
        return ZGNS_INVALID_ADDRESS;

    SteamNetworkingConfigValue_t option = status_callback_option();
    const HSteamNetConnection connection = sockets->ConnectByIPAddress(
        to_native(*address), 1, &option
    );
    if (connection == k_HSteamNetConnection_Invalid)
        return ZGNS_FAILED;

    *out = connection;
    return ZGNS_OK;
}

zgns_result_t zgns_accept(
    zgns_listener_t listener,
    zgns_connection_t connection
)
{
    if (sockets == nullptr)
        return ZGNS_NOT_INITIALIZED;
    if (listener.socket == k_HSteamListenSocket_Invalid ||
        listener.poll_group == k_HSteamNetPollGroup_Invalid)
        return ZGNS_INVALID_HANDLE;

    SteamNetConnectionInfo_t info;
    if (!sockets->GetConnectionInfo(connection, &info) ||
        info.m_hListenSocket != listener.socket)
        return ZGNS_INVALID_HANDLE;

    const EResult accepted = sockets->AcceptConnection(connection);
    if (accepted != k_EResultOK)
        return map_result(accepted);

    if (!sockets->SetConnectionPollGroup(connection, listener.poll_group)) {
        sockets->CloseConnection(connection, 0, nullptr, false);
        return ZGNS_INVALID_HANDLE;
    }
    return ZGNS_OK;
}

void zgns_close_listener(zgns_listener_t listener)
{
    if (sockets == nullptr)
        return;
    if (listener.socket != k_HSteamListenSocket_Invalid)
        sockets->CloseListenSocket(listener.socket);
    if (listener.poll_group != k_HSteamNetPollGroup_Invalid)
        sockets->DestroyPollGroup(listener.poll_group);
}

void zgns_close_connection(zgns_connection_t connection)
{
    if (sockets != nullptr && connection != k_HSteamNetConnection_Invalid)
        sockets->CloseConnection(connection, 0, nullptr, false);
}

zgns_result_t zgns_send(
    zgns_connection_t connection,
    const void *data,
    uint32_t size,
    uint32_t flags
)
{
    if (sockets == nullptr)
        return ZGNS_NOT_INITIALIZED;
    if (size > static_cast<uint32_t>(k_cbMaxSteamNetworkingSocketsMessageSizeSend))
        return ZGNS_MESSAGE_TOO_LARGE;

    return map_result(sockets->SendMessageToConnection(
        connection, data, size, static_cast<int>(flags), nullptr
    ));
}

int zgns_receive_connection(
    zgns_connection_t connection,
    zgns_message_t *out
)
{
    if (sockets == nullptr || out == nullptr)
        return -1;

    SteamNetworkingMessage_t *message = nullptr;
    const int count = sockets->ReceiveMessagesOnConnection(
        connection, &message, 1
    );
    if (count <= 0)
        return count;
    return receive_message(message, out);
}

int zgns_receive_poll_group(
    zgns_poll_group_t poll_group,
    zgns_message_t *out
)
{
    if (sockets == nullptr || out == nullptr)
        return -1;

    SteamNetworkingMessage_t *message = nullptr;
    const int count = sockets->ReceiveMessagesOnPollGroup(
        poll_group, &message, 1
    );
    if (count <= 0)
        return count;
    return receive_message(message, out);
}

void zgns_message_release(void *message)
{
    if (message != nullptr)
        static_cast<SteamNetworkingMessage_t *>(message)->Release();
}

bool zgns_poll_event(zgns_event_t *out)
{
    if (sockets == nullptr || out == nullptr)
        return false;

    sockets->RunCallbacks();

    std::lock_guard<std::mutex> lock(events_mutex);
    if (events.empty())
        return false;

    *out = events.front();
    events.pop_front();
    return true;
}
