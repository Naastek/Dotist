#ifndef DOTIST_NATIVE_H
#define DOTIST_NATIVE_H

typedef struct NativeStore NativeStore;

NativeStore *dotist_native_open(const char *database_path, char **error_out);
char *dotist_native_call(NativeStore *store, const char *request_json);
void dotist_native_string_free(char *value);
void dotist_native_close(NativeStore *store);

#endif
