use std::ffi::{c_char, c_int, c_void, CStr, CString};

// Dynamic loading through the C library: the global namespace (dlopen(NULL)), a shared library by name, a symbol
// looked up in it and called, and the error for a library that does not exist.
const RTLD_NOW: c_int = 2;

extern "C" {
    fn dlopen(file: *const c_char, mode: c_int) -> *mut c_void;
    fn dlsym(handle: *mut c_void, name: *const c_char) -> *mut c_void;
    fn dlclose(handle: *mut c_void) -> c_int;
    fn dlerror() -> *const c_char;
}

fn main() {
    unsafe {
        let global = dlopen(std::ptr::null(), RTLD_NOW);
        let strlen_name = CString::new("strlen").unwrap();
        let strlen: extern "C" fn(*const c_char) -> usize = std::mem::transmute(dlsym(global, strlen_name.as_ptr()));
        let text = CString::new("hello").unwrap();
        println!("strlen via dlsym: {}", strlen(text.as_ptr()));

        let libm = CString::new("libm.so.6").unwrap();
        let h = dlopen(libm.as_ptr(), RTLD_NOW);
        println!("opened libm: {}", !h.is_null());
        let cos_name = CString::new("cos").unwrap();
        let cos: extern "C" fn(f64) -> f64 = std::mem::transmute(dlsym(h, cos_name.as_ptr()));
        println!("cos(0) = {}", cos(0.0));
        println!("closed: {}", dlclose(h) == 0);

        let missing = CString::new("libnosuchthing.so").unwrap();
        let none = dlopen(missing.as_ptr(), RTLD_NOW);
        println!("missing is null: {}", none.is_null());
        let err = CStr::from_ptr(dlerror());
        println!("error names the library: {}", err.to_string_lossy().contains("libnosuchthing.so"));
    }
}
