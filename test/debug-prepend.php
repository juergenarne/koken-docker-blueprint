<?php
// Test environment only: log every PHP error/deprecation, even when the
// application calls error_reporting(0). Mounted via auto_prepend_file.
function __k85_log($type, $msg, $file, $line)
{
    $uri = $_SERVER['REQUEST_URI'] ?? 'cli';
    @file_put_contents('/tmp/koken85.log', sprintf("[%s] %s: %s in %s:%d (%s)\n", date('H:i:s'), $type, $msg, $file, $line, $uri), FILE_APPEND);
}
set_error_handler(function ($no, $msg, $file, $line) {
    $map = [E_DEPRECATED => 'DEPRECATED', E_USER_DEPRECATED => 'USER_DEPRECATED', E_NOTICE => 'NOTICE', E_USER_NOTICE => 'NOTICE', E_WARNING => 'WARNING', E_USER_WARNING => 'WARNING'];
    __k85_log($map[$no] ?? "E$no", $msg, $file, $line);
    return false;
});
set_exception_handler(function ($e) {
    __k85_log('UNCAUGHT ' . get_class($e), $e->getMessage(), $e->getFile(), $e->getLine());
    __k85_log('TRACE', "\n" . $e->getTraceAsString(), '', 0);
});
register_shutdown_function(function () {
    $e = error_get_last();
    if ($e && in_array($e['type'], [E_ERROR, E_PARSE, E_CORE_ERROR, E_COMPILE_ERROR, E_RECOVERABLE_ERROR])) {
        __k85_log('FATAL', $e['message'], $e['file'], $e['line']);
    }
});
// CodeIgniter installs _exception_handler() as error handler, but only defines
// it when it does not exist yet – so we provide our own logging variant.
function _exception_handler($severity, $message, $filepath, $line)
{
    $map = [E_DEPRECATED => 'DEPRECATED', E_USER_DEPRECATED => 'USER_DEPRECATED', E_NOTICE => 'NOTICE', E_USER_NOTICE => 'NOTICE', E_WARNING => 'WARNING', E_USER_WARNING => 'WARNING'];
    __k85_log(($map[$severity] ?? "E$severity") . ' (CI)', $message, $filepath, $line);
}
