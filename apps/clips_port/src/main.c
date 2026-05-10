/**
 * CLIPS Port Program - Erlang Port stdin/stdout JSON Protocol
 *
 * Protocol: Line-delimited JSON on stdin, JSON responses on stdout
 *
 * Operations:
 *   {"op":"reset"}
 *   {"op":"load","file":"path/to/rules.clp"}
 *   {"op":"assert","fact":"(template slot1 slot2 ...)"}
 *   {"op":"retract","fact-id":42}
 *   {"op":"retract-all"}
 *   {"op":"run","limit":-1}
 *   {"op":"query","template":"name","slot":"slot","value":"val"}
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <fcntl.h>
#include "clips_bridge.h"

#define MAX_LINE 1048576

static char line_buffer[MAX_LINE];
static clips_env_t g_env = NULL;

/* Simple JSON value extraction with escaped quote handling */
static const char* json_get_string(const char *json, const char *key, char *buf, size_t bufsize) {
    char search[256];
    snprintf(search, sizeof(search), "\"%s\":\"", key);
    const char *start = strstr(json, search);
    if (!start) return NULL;
    start += strlen(search);
    /* Find closing quote, skipping escaped quotes */
    size_t i = 0, j = 0;
    while (start[i] != '\0' && j < bufsize - 1) {
        if (start[i] == '\\' && start[i+1] == '"') {
            buf[j++] = '"';
            i += 2;
        } else if (start[i] == '"') {
            break;
        } else {
            buf[j++] = start[i++];
        }
    }
    buf[j] = '\0';
    return buf;
}

static long long json_get_int(const char *json, const char *key) {
    char search[256];
    snprintf(search, sizeof(search), "\"%s\":", key);
    const char *start = strstr(json, search);
    if (!start) return -1;
    start += strlen(search);
    return atoll(start);
}

static void send_response(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    vprintf(fmt, args);
    va_end(args);
    printf("\n");
    fflush(stdout);
}

static void handle_line(const char *line) {
    char buf1[8192], buf2[8192], buf3[8192];

    if (strstr(line, "\"op\":\"reset\"")) {
        clips_bridge_reset(g_env);
        send_response("{\"ok\":true}");

    } else if (strstr(line, "\"op\":\"load\"")) {
        if (json_get_string(line, "file", buf1, sizeof(buf1))) {
            /* Suppress CLIPS output during load to avoid corrupting protocol */
            int saved_stdout = dup(1);
            int devnull = open("/dev/null", O_WRONLY);
            dup2(devnull, 1);
            close(devnull);
            int result = clips_bridge_load(g_env, buf1);
            /* Restore stdout */
            dup2(saved_stdout, 1);
            close(saved_stdout);
            if (result == 0) {
                send_response("{\"ok\":true}");
            } else {
                send_response("{\"error\":\"load failed\"}");
            }
        } else {
            send_response("{\"error\":\"missing file\"}");
        }

    } else if (strstr(line, "\"op\":\"assert\"")) {
        if (json_get_string(line, "fact", buf1, sizeof(buf1))) {
            long long fid = clips_bridge_assert_json(g_env, buf1, strlen(buf1));
            if (fid >= 0) {
                send_response("{\"ok\":true,\"fact-id\":%lld}", fid);
            } else {
                send_response("{\"error\":\"assert failed\"}");
            }
        } else {
            send_response("{\"error\":\"missing fact\"}");
        }

    } else if (strstr(line, "\"op\":\"retract-all\"")) {
        clips_bridge_retract_all(g_env, "");
        send_response("{\"ok\":true}");

    } else if (strstr(line, "\"op\":\"retract\"")) {
        long long fid = json_get_int(line, "fact-id");
        clips_bridge_retract(g_env, fid);
        send_response("{\"ok\":true}");

    } else if (strstr(line, "\"op\":\"run\"")) {
        long long limit = json_get_int(line, "limit");
        int fired = clips_bridge_run(g_env, (int)limit);
        send_response("{\"ok\":true,\"fired\":%d}", fired);

    } else if (strstr(line, "\"op\":\"query\"")) {
        const char *tmpl = json_get_string(line, "template", buf1, sizeof(buf1));
        const char *slot = json_get_string(line, "slot", buf2, sizeof(buf2));
        const char *value = json_get_string(line, "value", buf3, sizeof(buf3));
        if (tmpl && slot && value) {
            char *result = clips_bridge_query(g_env, tmpl, slot, value);
            send_response("{\"ok\":true,\"result\":%s}", result);
            clips_bridge_free(result);
        } else {
            send_response("{\"ok\":true,\"result\":null}");
        }

    } else {
        send_response("{\"error\":\"unknown op\"}");
    }
}

int main(void) {
    g_env = clips_bridge_init();
    if (!g_env) {
        fprintf(stderr, "Failed to initialize CLIPS environment\n");
        return 1;
    }

    while (fgets(line_buffer, MAX_LINE, stdin) != NULL) {
        size_t len = strlen(line_buffer);
        if (len > 0 && line_buffer[len - 1] == '\n') {
            line_buffer[--len] = '\0';
        }
        if (len == 0) continue;
        handle_line(line_buffer);
    }

    clips_bridge_destroy(g_env);
    return 0;
}
