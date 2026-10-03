#ifndef INTATIS_CURL_TRANSPORT_H
#define INTATIS_CURL_TRANSPORT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef size_t (*intatis_curl_data_callback)(
    const uint8_t *bytes,
    size_t length,
    void *context);

typedef int32_t (*intatis_curl_cancel_callback)(void *context);

typedef struct {
    const char *url;
    const char *method;
    const uint8_t *body;
    size_t body_length;
    const char *const *headers;
    size_t header_count;
    const char *const *resolve_entries;
    size_t resolve_entry_count;
    const char *pinned_public_key;
    int64_t timeout_milliseconds;
    int64_t connect_timeout_milliseconds;
    int32_t direct_proxy;
} intatis_curl_request;

/// Performs one HTTP hop with redirects disabled. A non-zero callback return
/// mismatch aborts the transfer. `primary_ip` and `error_buffer` are always
/// NUL-terminated when their capacities are non-zero.
int32_t intatis_curl_perform(
    const intatis_curl_request *request,
    intatis_curl_data_callback header_callback,
    intatis_curl_data_callback body_callback,
    intatis_curl_cancel_callback cancel_callback,
    void *context,
    int64_t *status_code,
    char *primary_ip,
    size_t primary_ip_capacity,
    char *error_buffer,
    size_t error_buffer_capacity);

int32_t intatis_curl_code_ssl_pinned_public_key_mismatch(void);

#ifdef __cplusplus
}
#endif

#endif
