/// The browser build of the goldens test, which runs only on the VM but
/// is compiled for the browser suite all the same: web has no
/// `LocalFileComparator` to extend.
void useTolerantGoldens(String testFile) {}
