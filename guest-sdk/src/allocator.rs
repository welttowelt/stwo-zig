//! Simple bump allocator for `#[no_std]` guest programs.
//!
//! Uses a static heap region. Thread-safe is not needed since
//! the guest runs single-threaded in the zkVM.

use core::alloc::{GlobalAlloc, Layout};
use core::cell::UnsafeCell;
use core::ptr;

/// Default heap size: 64 MiB. Guests requiring more can override
/// the HEAP_SIZE symbol at link time.
const DEFAULT_HEAP_SIZE: usize = 64 * 1024 * 1024;

/// A simple bump allocator for the guest heap.
pub struct BumpAllocator {
    heap: UnsafeCell<[u8; DEFAULT_HEAP_SIZE]>,
    offset: UnsafeCell<usize>,
}

unsafe impl Sync for BumpAllocator {}

impl BumpAllocator {
    pub const fn new() -> Self {
        Self {
            heap: UnsafeCell::new([0u8; DEFAULT_HEAP_SIZE]),
            offset: UnsafeCell::new(0),
        }
    }
}

unsafe impl GlobalAlloc for BumpAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let offset = &mut *self.offset.get();
        let heap = &mut *self.heap.get();

        // Align up.
        let align = layout.align();
        let aligned = (*offset + align - 1) & !(align - 1);
        let end = aligned + layout.size();

        if end > heap.len() {
            // Out of memory.
            ptr::null_mut()
        } else {
            *offset = end;
            heap.as_mut_ptr().add(aligned)
        }
    }

    unsafe fn dealloc(&self, _ptr: *mut u8, _layout: Layout) {
        // Bump allocator: deallocation is a no-op.
    }
}

#[global_allocator]
static ALLOCATOR: BumpAllocator = BumpAllocator::new();
