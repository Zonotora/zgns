#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint32_t zgns_connection_t;
typedef uint32_t zgns_listen_socket_t;
typedef uint32_t zgns_poll_group_t;

typedef struct zgns_address {
    uint8_t ip[16];
    uint16_t port;
} zgns_address_t;

typedef struct zgns_listener {
    zgns_listen_socket_t socket;
    zgns_poll_group_t poll_group;
} zgns_listener_t;

typedef struct zgns_event {
    zgns_connection_t connection;
    zgns_listen_socket_t listen_socket;
    int32_t old_state;
    int32_t state;
    int32_t end_reason;
    char end_debug[128];
} zgns_event_t;

/* The message payload is valid until zgns_message_release is called. */
typedef struct zgns_message {
    const void *data;
    uint32_t size;
    zgns_connection_t connection;
    int64_t connection_user_data;
    int64_t received_at;
    int64_t number;
    uint32_t flags;
    void *internal;
} zgns_message_t;

typedef enum zgns_result {
    ZGNS_OK = 0,
    ZGNS_NOT_INITIALIZED = 1,
    ZGNS_INVALID_ADDRESS = 2,
    ZGNS_INVALID_HANDLE = 3,
    ZGNS_INVALID_STATE = 4,
    ZGNS_MESSAGE_TOO_LARGE = 5,
    ZGNS_SEND_QUEUE_FULL = 6,
    ZGNS_MESSAGE_DROPPED = 7,
    ZGNS_FAILED = 8,
} zgns_result_t;

enum {
    ZGNS_SEND_UNRELIABLE = 0,
    ZGNS_SEND_NO_NAGLE = 1,
    ZGNS_SEND_NO_DELAY = 4,
    ZGNS_SEND_RELIABLE = 8,
};

bool zgns_init(char *error_buffer, size_t error_buffer_size);
void zgns_kill(void);

bool zgns_address_parse(const char *text, size_t text_len, zgns_address_t *out);
size_t zgns_address_format(
    const zgns_address_t *address,
    char *buffer,
    size_t buffer_size
);
void zgns_address_any(uint16_t port, zgns_address_t *out);
void zgns_address_ipv4(
    uint8_t a,
    uint8_t b,
    uint8_t c,
    uint8_t d,
    uint16_t port,
    zgns_address_t *out
);

zgns_result_t zgns_listen(
    const zgns_address_t *address,
    zgns_listener_t *out
);
zgns_result_t zgns_connect(
    const zgns_address_t *address,
    zgns_connection_t *out
);
zgns_result_t zgns_accept(
    zgns_listener_t listener,
    zgns_connection_t connection
);
void zgns_close_listener(zgns_listener_t listener);
void zgns_close_connection(zgns_connection_t connection);

zgns_result_t zgns_send(
    zgns_connection_t connection,
    const void *data,
    uint32_t size,
    uint32_t flags
);

/* Returns 1 for a message, 0 if none is ready, and -1 for an invalid handle. */
int zgns_receive_connection(
    zgns_connection_t connection,
    zgns_message_t *out
);
int zgns_receive_poll_group(
    zgns_poll_group_t poll_group,
    zgns_message_t *out
);
void zgns_message_release(void *message);

/* Dispatches callbacks and returns one queued event, if any. */
bool zgns_poll_event(zgns_event_t *out);

#ifdef __cplusplus
}
#endif
