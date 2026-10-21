// SPDX-License-Identifier: GPL-3.0-or-later
#include "CCurlTransport.h"
#include <curl/curl.h>
#include <pthread.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct WSCurlSession { CURL *easy; };
static pthread_once_t init_once = PTHREAD_ONCE_INIT;
static int init_result;
static void initialize(void) { init_result = curl_global_init(CURL_GLOBAL_DEFAULT); }

WSCurlSession *ws_curl_create(void) {
    pthread_once(&init_once, initialize);
    if (init_result != CURLE_OK) return NULL;
    WSCurlSession *session = calloc(1, sizeof(*session));
    if (!session) return NULL;
    session->easy = curl_easy_init();
    if (!session->easy) { free(session); return NULL; }
    return session;
}
void ws_curl_destroy(WSCurlSession *session) {
    if (session) { curl_easy_cleanup(session->easy); free(session); }
}
void ws_curl_result_free(WSCurlResult *result) { free(result->body); result->body = NULL; result->body_size = 0; }

static long tls_constant(int version, int maximum) {
    long value = version == 10 ? CURL_SSLVERSION_TLSv1_0 : version == 11 ? CURL_SSLVERSION_TLSv1_1
               : version == 13 ? CURL_SSLVERSION_TLSv1_3 : CURL_SSLVERSION_TLSv1_2;
    return maximum ? (version ? value << 16 : CURL_SSLVERSION_MAX_DEFAULT) : value;
}
static CURLcode apply_network(CURL *easy, const WSNetworkOptions *network, int tls, int ftp) {
    CURLcode code;
    long timeout = network->timeout > 0 ? network->timeout : 15;
#define TRY(option, value) do { code = curl_easy_setopt(easy, option, value); if (code != CURLE_OK) return code; } while (0)
    TRY(CURLOPT_PROXY, network->proxy ? network->proxy : "");
    if (network->proxy && *network->proxy && ftp) TRY(CURLOPT_HTTPPROXYTUNNEL, 1L);
    TRY(CURLOPT_CONNECTTIMEOUT, timeout);
    if (ftp) TRY(CURLOPT_FTP_RESPONSE_TIMEOUT, network->timeout > 0 ? timeout : 30L);
    TRY(CURLOPT_LOW_SPEED_LIMIT, 1L);
    TRY(CURLOPT_LOW_SPEED_TIME, timeout > 45 ? timeout : 45L);
    TRY(CURLOPT_IPRESOLVE, network->ip_resolve == 4 ? (long)CURL_IPRESOLVE_V4 : network->ip_resolve == 6 ? (long)CURL_IPRESOLVE_V6 : (long)CURL_IPRESOLVE_WHATEVER);
    if (tls) TRY(CURLOPT_SSLVERSION, tls_constant(network->tls_min, 0) | tls_constant(network->tls_max, 1));
#undef TRY
    return CURLE_OK;
}

typedef struct {
    const WSCurlRequest *request;
    WSCurlResult *result;
    WSProgress progress;
    void *context;
} Transfer;

static size_t receive_body(char *buffer, size_t size, size_t count, void *opaque) {
    Transfer *transfer = opaque;
    if (size && count > SIZE_MAX / size) return 0;
    size_t length = size * count;
    if (transfer->request->operation == 1) {
        size_t written = 0;
        while (written < length) {
            ssize_t n = write(transfer->request->file_descriptor, buffer + written, length - written);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { transfer->result->local_errno = errno ? errno : EIO; return 0; }
            written += (size_t)n;
        }
        return length;
    }
    WSCurlResult *result = transfer->result;
    if (length > 16 * 1024 * 1024 || result->body_size > 16 * 1024 * 1024 - length) {
        result->body_too_large = 1; return 0;
    }
    unsigned char *body = realloc(result->body, result->body_size + length + 1);
    if (!body) { result->local_errno = ENOMEM; return 0; }
    result->body = body;
    memcpy(body + result->body_size, buffer, length);
    result->body_size += length; body[result->body_size] = 0;
    return length;
}
static size_t send_body(char *buffer, size_t size, size_t count, void *opaque) {
    Transfer *transfer = opaque;
    if (size && count > SIZE_MAX / size) return CURL_READFUNC_ABORT;
    ssize_t n;
    do { n = read(transfer->request->file_descriptor, buffer, size * count); } while (n < 0 && errno == EINTR);
    if (n < 0) { transfer->result->local_errno = errno; return CURL_READFUNC_ABORT; }
    return (size_t)n;
}
static int report_progress(void *opaque, curl_off_t download_total, curl_off_t downloaded,
                           curl_off_t upload_total, curl_off_t uploaded) {
    Transfer *transfer = opaque;
    if (!transfer->progress) return 0;
    return transfer->request->operation == 2
        ? transfer->progress(transfer->context, upload_total, uploaded)
        : transfer->progress(transfer->context, download_total, downloaded);
}

void ws_curl_perform(WSCurlSession *session, const WSCurlRequest *request,
                     WSProgress progress, void *context, WSCurlResult *result) {
    memset(result, 0, sizeof(*result));
    Transfer transfer = { request, result, progress, context };
    CURL *easy = session->easy;
    curl_easy_reset(easy);
    struct curl_slist *commands = NULL;
    CURLcode code;
#define SET(option, value) do { code = curl_easy_setopt(easy, option, value); if (code != CURLE_OK) goto finish; } while (0)
    SET(CURLOPT_ERRORBUFFER, result->error);
    SET(CURLOPT_URL, request->url);
    SET(CURLOPT_USERNAME, request->username);
    SET(CURLOPT_PASSWORD, request->password);
    SET(CURLOPT_PROTOCOLS, (long)(CURLPROTO_FTP | CURLPROTO_FTPS));
    SET(CURLOPT_NETRC, (long)CURL_NETRC_IGNORED);
    SET(CURLOPT_FOLLOWLOCATION, 0L);
    SET(CURLOPT_NOSIGNAL, 1L);
    code = apply_network(easy, &request->network, request->tls_mode, 1);
    if (code != CURLE_OK) goto finish;
    SET(CURLOPT_FTP_SKIP_PASV_IP, 1L);
    SET(CURLOPT_FTP_FILEMETHOD, (long)CURLFTPMETHOD_SINGLECWD);
    SET(CURLOPT_SSL_VERIFYPEER, 1L);
    SET(CURLOPT_SSL_VERIFYHOST, 2L);
    SET(CURLOPT_USE_SSL, (long)(request->tls_mode ? CURLUSESSL_ALL : CURLUSESSL_NONE));
    if (request->ca_file && *request->ca_file) SET(CURLOPT_CAINFO, request->ca_file);
    SET(CURLOPT_WRITEFUNCTION, receive_body);
    SET(CURLOPT_WRITEDATA, &transfer);
    SET(CURLOPT_XFERINFOFUNCTION, report_progress);
    SET(CURLOPT_XFERINFODATA, &transfer);
    SET(CURLOPT_NOPROGRESS, 0L);
    if (request->method && *request->method) SET(CURLOPT_CUSTOMREQUEST, request->method);
    if (request->operation == 2) {
        SET(CURLOPT_UPLOAD, 1L);
        SET(CURLOPT_READFUNCTION, send_body);
        SET(CURLOPT_READDATA, &transfer);
        SET(CURLOPT_INFILESIZE_LARGE, (curl_off_t)request->upload_size);
    }
    if (request->operation == 3) SET(CURLOPT_NOBODY, 1L);
    for (size_t i = 0; i < request->command_count; i++) {
        struct curl_slist *next = curl_slist_append(commands, request->commands[i]);
        if (!next) { code = CURLE_OUT_OF_MEMORY; goto finish; }
        commands = next;
    }
    if (commands) SET(CURLOPT_QUOTE, commands);
    code = curl_easy_perform(easy);
finish:
    result->code = code;
    curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &result->reply);
    char *entry = NULL;
    curl_easy_getinfo(easy, CURLINFO_FTP_ENTRY_PATH, &entry);
    if (entry && strlen(entry) >= sizeof(result->entry_path)) {
        result->code = code = CURLE_URL_MALFORMAT;
        strlcpy(result->error, "The FTP login directory exceeds 4095 bytes.", sizeof(result->error));
    } else if (entry) strlcpy(result->entry_path, entry, sizeof(result->entry_path));
    if (code && !*result->error) strlcpy(result->error, curl_easy_strerror(code), sizeof(result->error));
    curl_slist_free_all(commands);
    /* Discard request pointers before Swift releases its temporary buffers. Keep the connection cache. */
    curl_easy_reset(easy);
#undef SET
}

/* HTTP/WebDAV uses independent request options; FTP behavior is unchanged. */
typedef struct {
    Transfer transfer;
    WSCurlRequest body_request;
    const WSHTTPRequest *request;
    WSHTTPResult *result;
    int64_t sent;
} HTTPTransfer;

static size_t receive_headers(char *buffer, size_t size, size_t count, void *opaque) {
    HTTPTransfer *http = opaque;
    if (size && count > SIZE_MAX / size) return 0;
    size_t length = size * count;
    WSHTTPResult *result = http->result;
    if (length >= 5 && !memcmp(buffer, "HTTP/", 5)) {
        free(result->headers); result->headers = NULL; result->headers_size = 0;
        free(result->response.body); result->response.body = NULL; result->response.body_size = 0;
        const char *space = memchr(buffer, ' ', length);
        long status = 0;
        if (space && buffer + length - space >= 4 && space[1] >= '0' && space[1] <= '9' &&
            space[2] >= '0' && space[2] <= '9' && space[3] >= '0' && space[3] <= '9')
            status = (space[1] - '0') * 100 + (space[2] - '0') * 10 + space[3] - '0';
        /* Error/authentication bodies must never be appended to a download file. */
        http->body_request.operation = http->request->operation == 1 && status >= 200 && status < 300 ? 1 : 0;
    }
    if (length > 256 * 1024 || result->headers_size > 256 * 1024 - length) {
        result->response.body_too_large = 1; return 0;
    }
    char *headers = realloc(result->headers, result->headers_size + length + 1);
    if (!headers) { result->response.local_errno = ENOMEM; return 0; }
    result->headers = headers;
    memcpy(headers + result->headers_size, buffer, length);
    result->headers_size += length; headers[result->headers_size] = 0;
    return length;
}
static int http_progress(void *opaque, curl_off_t download_total, curl_off_t downloaded,
                         curl_off_t upload_total, curl_off_t uploaded) {
    HTTPTransfer *http = opaque;
    if (!http->transfer.progress) return 0;
    return http->request->operation == 2
        ? http->transfer.progress(http->transfer.context, upload_total, uploaded)
        : http->transfer.progress(http->transfer.context, download_total, downloaded);
}
static int seek_body(void *opaque, curl_off_t offset, int origin) {
    Transfer *transfer = opaque;
    return lseek(transfer->request->file_descriptor, offset, origin) == -1 ? CURL_SEEKFUNC_FAIL : CURL_SEEKFUNC_OK;
}
/* Ranged uploads never depend on the descriptor's offset and stop exactly at upload_size. */
static size_t send_range(char *buffer, size_t size, size_t count, void *opaque) {
    HTTPTransfer *http = opaque;
    if (size && count > SIZE_MAX / size) return CURL_READFUNC_ABORT;
    int64_t remaining = http->request->upload_size - http->sent;
    if (remaining <= 0) return 0;
    size_t wanted = size * count;
    if ((uint64_t)wanted > (uint64_t)remaining) wanted = (size_t)remaining;
    ssize_t n;
    do { n = pread(http->request->file_descriptor, buffer, wanted, (off_t)(http->request->upload_offset + http->sent)); } while (n < 0 && errno == EINTR);
    if (n <= 0) { http->result->response.local_errno = n < 0 ? errno : EIO; return CURL_READFUNC_ABORT; }
    http->sent += n;
    return (size_t)n;
}
static int seek_range(void *opaque, curl_off_t offset, int origin) {
    HTTPTransfer *http = opaque;
    if (origin != SEEK_SET || offset < 0 || offset > http->request->upload_size) return CURL_SEEKFUNC_FAIL;
    http->sent = offset;
    return CURL_SEEKFUNC_OK;
}
void ws_http_result_free(WSHTTPResult *result) {
    ws_curl_result_free(&result->response); free(result->headers); result->headers = NULL; result->headers_size = 0;
}
void ws_http_perform(WSCurlSession *session, const WSHTTPRequest *request,
                     WSProgress progress, void *context, WSHTTPResult *result) {
    memset(result, 0, sizeof(*result));
    HTTPTransfer http = {0};
    http.request = request; http.result = result;
    http.body_request.operation = request->operation;
    http.body_request.file_descriptor = request->file_descriptor;
    http.transfer = (Transfer){ &http.body_request, &result->response, progress, context };
    CURL *easy = session->easy;
    curl_easy_reset(easy);
    struct curl_slist *headers = NULL;
    CURLcode code;
#define SET(option, value) do { code = curl_easy_setopt(easy, option, value); if (code != CURLE_OK) goto finish_http; } while (0)
    SET(CURLOPT_ERRORBUFFER, result->response.error);
    SET(CURLOPT_URL, request->url);
    /* Callers send exact, already-encoded paths; never collapse "/./" or "/../" in object keys. */
    SET(CURLOPT_PATH_AS_IS, 1L);
    SET(CURLOPT_PROTOCOLS, (long)(request->use_tls ? CURLPROTO_HTTPS : CURLPROTO_HTTP));
    if (request->basic_auth) {
        SET(CURLOPT_USERNAME, request->username); SET(CURLOPT_PASSWORD, request->password);
        SET(CURLOPT_HTTPAUTH, (long)CURLAUTH_BASIC);
    }
    SET(CURLOPT_NETRC, (long)CURL_NETRC_IGNORED);
    SET(CURLOPT_FOLLOWLOCATION, 0L); SET(CURLOPT_UNRESTRICTED_AUTH, 0L);
    SET(CURLOPT_NOSIGNAL, 1L);
    code = apply_network(easy, &request->network, request->use_tls, 0);
    if (code != CURLE_OK) goto finish_http;
    SET(CURLOPT_SSL_VERIFYPEER, 1L); SET(CURLOPT_SSL_VERIFYHOST, 2L);
    if (request->ca_file && *request->ca_file) SET(CURLOPT_CAINFO, request->ca_file);
    SET(CURLOPT_HTTP_VERSION, (long)CURL_HTTP_VERSION_1_1);
    SET(CURLOPT_WRITEFUNCTION, receive_body); SET(CURLOPT_WRITEDATA, &http.transfer);
    SET(CURLOPT_HEADERFUNCTION, receive_headers); SET(CURLOPT_HEADERDATA, &http);
    SET(CURLOPT_XFERINFOFUNCTION, http_progress); SET(CURLOPT_XFERINFODATA, &http);
    SET(CURLOPT_NOPROGRESS, 0L);
    if (request->operation == 2 && request->ranged_upload) {
        SET(CURLOPT_UPLOAD, 1L);
        SET(CURLOPT_READFUNCTION, send_range); SET(CURLOPT_READDATA, &http);
        SET(CURLOPT_SEEKFUNCTION, seek_range); SET(CURLOPT_SEEKDATA, &http);
        SET(CURLOPT_INFILESIZE_LARGE, (curl_off_t)request->upload_size);
    } else if (request->operation == 2) {
        SET(CURLOPT_UPLOAD, 1L);
        SET(CURLOPT_READFUNCTION, send_body); SET(CURLOPT_READDATA, &http.transfer);
        SET(CURLOPT_SEEKFUNCTION, seek_body); SET(CURLOPT_SEEKDATA, &http.transfer);
        SET(CURLOPT_INFILESIZE_LARGE, (curl_off_t)request->upload_size);
    } else if (request->body_size) {
        SET(CURLOPT_POSTFIELDS, request->body);
        SET(CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)request->body_size);
    }
    SET(CURLOPT_CUSTOMREQUEST, request->method);
    /* HEAD responses advertise a body length that never follows. */
    if (!strcmp(request->method, "HEAD")) SET(CURLOPT_NOBODY, 1L);
    for (size_t i = 0; i < request->header_count; i++) {
        struct curl_slist *next = curl_slist_append(headers, request->headers[i]);
        if (!next) { code = CURLE_OUT_OF_MEMORY; goto finish_http; }
        headers = next;
    }
    if (headers) SET(CURLOPT_HTTPHEADER, headers);
    code = curl_easy_perform(easy);
finish_http:
    result->response.code = code;
    curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &result->response.reply);
    if (code && !*result->response.error) strlcpy(result->response.error, curl_easy_strerror(code), sizeof(result->response.error));
    curl_slist_free_all(headers);
    curl_easy_reset(easy);
#undef SET
}
