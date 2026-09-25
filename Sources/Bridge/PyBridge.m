#import "PyBridge.h"
#import <Python/Python.h>

static int g_initialized = 0;

static void append_path(PyWideStringList *list, NSString *path) {
    wchar_t *w = Py_DecodeLocale([path UTF8String], NULL);
    if (w) {
        PyWideStringList_Append(list, w);
        PyMem_RawFree(w);
    }
}

int py_bootstrap(void) {
    if (g_initialized) {
        return 0;
    }

    NSString *resourcePath = [[NSBundle mainBundle] resourcePath];
    NSString *pythonHome = [resourcePath stringByAppendingPathComponent:@"python"];

    // Discover the python3.X directory inside python/lib.
    NSString *libDir = [pythonHome stringByAppendingPathComponent:@"lib"];
    NSString *pyVerDir = nil;
    NSArray<NSString *> *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:libDir error:nil];
    for (NSString *e in entries) {
        if ([e hasPrefix:@"python3."]) { pyVerDir = e; break; }
    }
    if (!pyVerDir) {
        NSLog(@"[PyBridge] Could not locate python3.X under %@", libDir);
        return 1;
    }
    NSString *stdlib = [libDir stringByAppendingPathComponent:pyVerDir];
    NSString *dynload = [stdlib stringByAppendingPathComponent:@"lib-dynload"];
    NSString *appDir = [resourcePath stringByAppendingPathComponent:@"app"];
    NSString *appPackages = [resourcePath stringByAppendingPathComponent:@"app_packages"];

    PyStatus status;

    PyPreConfig preconfig;
    PyPreConfig_InitPythonConfig(&preconfig);
    preconfig.utf8_mode = 1;
    status = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(status)) {
        NSLog(@"[PyBridge] Py_PreInitialize failed: %s", status.err_msg ? status.err_msg : "?");
        return 2;
    }

    PyConfig config;
    PyConfig_InitPythonConfig(&config);
    config.buffered_stdio = 0;
    config.write_bytecode = 0;
    config.install_signal_handlers = 1;
#if defined(__has_include)
    // use_system_logger exists on iOS builds of CPython 3.13+.
    config.use_system_logger = 1;
#endif

    status = PyConfig_SetBytesString(&config, &config.home, [pythonHome UTF8String]);
    if (PyStatus_Exception(status)) {
        NSLog(@"[PyBridge] set home failed");
        PyConfig_Clear(&config);
        return 3;
    }

    config.module_search_paths_set = 1;
    append_path(&config.module_search_paths, stdlib);
    append_path(&config.module_search_paths, dynload);
    append_path(&config.module_search_paths, appDir);
    append_path(&config.module_search_paths, appPackages);

    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        NSLog(@"[PyBridge] Py_InitializeFromConfig failed: %s", status.err_msg ? status.err_msg : "?");
        return 4;
    }

    g_initialized = 1;
    NSLog(@"[PyBridge] CPython initialized. home=%@", pythonHome);

    // After initialization this thread holds the GIL. Release it so that
    // subsequent PyGILState_Ensure() calls (from any thread) can acquire it;
    // otherwise the first py_call_json deadlocks.
    PyEval_SaveThread();
    return 0;
}

char *py_call_json(const char *module_name, const char *func_name, const char *json_arg) {
    if (!g_initialized) {
        if (py_bootstrap() != 0) {
            return NULL;
        }
    }

    PyGILState_STATE gil = PyGILState_Ensure();
    char *result = NULL;

    PyObject *module = PyImport_ImportModule(module_name);
    if (!module) {
        PyErr_Print();
        NSLog(@"[PyBridge] import '%s' failed", module_name);
        goto done;
    }

    PyObject *func = PyObject_GetAttrString(module, func_name);
    if (!func || !PyCallable_Check(func)) {
        PyErr_Print();
        NSLog(@"[PyBridge] attr '%s' not callable", func_name);
        Py_XDECREF(func);
        Py_DECREF(module);
        goto done;
    }

    PyObject *arg = PyUnicode_FromString(json_arg ? json_arg : "{}");
    PyObject *ret = PyObject_CallFunctionObjArgs(func, arg, NULL);
    Py_DECREF(arg);
    Py_DECREF(func);
    Py_DECREF(module);

    if (!ret) {
        PyErr_Print();
        NSLog(@"[PyBridge] call '%s.%s' raised", module_name, func_name);
        goto done;
    }

    if (PyUnicode_Check(ret)) {
        const char *utf8 = PyUnicode_AsUTF8(ret);
        if (utf8) {
            result = strdup(utf8);
        }
    } else {
        NSLog(@"[PyBridge] '%s.%s' did not return a str", module_name, func_name);
    }
    Py_DECREF(ret);

done:
    PyGILState_Release(gil);
    return result;
}
