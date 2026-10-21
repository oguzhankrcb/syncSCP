// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef SYNCSCP_CURL_TRANSPORT_H
#define SYNCSCP_CURL_TRANSPORT_H
#include <stddef.h>
#include <stdint.h>

typedef struct WSCurlSession WSCurlSession;
/* Advanced Site Settings shared by FTP and HTTP. Zero values keep the previous defaults. */
typedef struct {
    const char *proxy;  /* "" for none, else e.g. "socks5h://host:1080" */
    long timeout;       /* seconds; connect and FTP response timeout */
    int ip_resolve;     /* 0: any, 4: IPv4, 6: IPv6 */
    int tls_min;        /* 0: TLS 1.2, else 10/11/12/13 */
    int tls_max;        /* 0: library default, else 10/11/12/13 */
} WSNetworkOptions;
typedef int (*WSProgress)(void *context, int64_t total, int64_t completed);
typedef struct {
    const char *url;
    const char *username;
    const char *password;
    const char *ca_file;
    const char *method;
    const char *const *commands;
    size_t command_count;
    int tls_mode; /* 0: FTP, 1: required explicit TLS, 2: implicit TLS */
    int operation; /* 0: listing, 1: download, 2: upload, 3: commands */
    int file_descriptor;
    int64_t upload_size;
    WSNetworkOptions network;
} WSCurlRequest;
typedef struct {
    int code;
    long reply;
    int local_errno;
    int body_too_large;
    unsigned char *body;
    size_t body_size;
    char error[256];
    char entry_path[4096];
} WSCurlResult;

WSCurlSession *ws_curl_create(void);
void ws_curl_destroy(WSCurlSession *session);
void ws_curl_result_free(WSCurlResult *result);
void ws_curl_perform(WSCurlSession *session, const WSCurlRequest *request,
                     WSProgress progress, void *context, WSCurlResult *result);

typedef struct {
    const char *url, *username, *password, *ca_file, *method;
    const char *const *headers;
    size_t header_count;
    const unsigned char *body;
    size_t body_size;
    int operation; /* 0: memory response, 1: download, 2: upload */
    int file_descriptor;
    int64_t upload_size;
    int use_tls;
    /* S3: credentials are signed by the caller, uploads read [offset, offset+size) with pread. */
    int basic_auth;
    int ranged_upload;
    int64_t upload_offset;
    WSNetworkOptions network;
} WSHTTPRequest;
typedef struct {
    WSCurlResult response;
    char *headers;
    size_t headers_size;
} WSHTTPResult;
void ws_http_perform(WSCurlSession *session, const WSHTTPRequest *request,
                     WSProgress progress, void *context, WSHTTPResult *result);
void ws_http_result_free(WSHTTPResult *result);
#endif
