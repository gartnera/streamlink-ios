#ifndef PyBridge_h
#define PyBridge_h

#import <Foundation/Foundation.h>

/// Initialize the embedded CPython interpreter.
///
/// Computes PYTHONHOME / module search paths from the app bundle
/// (python/, app/, app_packages/) and calls Py_InitializeFromConfig with the
/// settings iOS requires (UTF-8 mode, unbuffered stdio, no bytecode writing,
/// system logger). Safe to call more than once; only the first call initializes.
///
/// Returns 0 on success, non-zero on failure.
int py_bootstrap(void);

/// Call `module.func(json_arg)` where `json_arg` is a UTF-8 JSON string and the
/// Python function returns a UTF-8 JSON string.
///
/// Returns a newly-allocated NUL-terminated C string (caller must free()), or
/// NULL on a hard failure (import/attr/GIL error). Python-level errors are
/// expected to be reported inside the returned JSON by the bridge module.
char *py_call_json(const char *module, const char *func, const char *json_arg);

#endif /* PyBridge_h */
