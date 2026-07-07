// ! NOTE
// The following code was written by Claude Sonnet 5, High Effort, on 02.07.2026
// This was the fastest way to get this allocator running while allowing me to learn how it works.
// I plan to eventually rewrite it myself.

use core::alloc::{GlobalAlloc, Layout};
use core::cell::UnsafeCell;
use core::ptr::NonNull;

/// A node in the intrusive free list. It lives *inside* the freed memory
/// block itself — no separate metadata storage is needed.
#[repr(C)]
struct FreeListNode {
    size: usize,
    next: Option<NonNull<FreeListNode>>,
}

/// All free-block addresses and sizes are kept as multiples of this. That
/// guarantees a split's leftover is always either exactly 0 or big enough to
/// describe itself as a FreeListNode — never an orphaned, unreclaimable sliver.
const GRANULARITY: usize = core::mem::size_of::<FreeListNode>();

pub struct FreeListAllocator {
    head: UnsafeCell<Option<NonNull<FreeListNode>>>,
    base: UnsafeCell<*mut u8>,
    len:  UnsafeCell<usize>,
    /// Bytes discarded because a split leftover fell below GRANULARITY.
    /// Should stay at 0 in normal operation — a canary for the old bug,
    /// and a fallback safety net for oversized-alignment requests (see below).
    leaked: UnsafeCell<usize>,
    alloc_ops: core::sync::atomic::AtomicU64,
    dealloc_ops: core::sync::atomic::AtomicU64,
}

unsafe impl Sync for FreeListAllocator {}

impl FreeListAllocator {
    pub const fn uninit() -> Self {
        Self {
            head: UnsafeCell::new(None),
            base: UnsafeCell::new(core::ptr::null_mut()),
            len:  UnsafeCell::new(0),
            leaked: UnsafeCell::new(0),
            alloc_ops: core::sync::atomic::AtomicU64::new(0),
            dealloc_ops: core::sync::atomic::AtomicU64::new(0),
        }
    }

    /// # Safety
    /// `base..base+len` must be valid, exclusively-owned, writable memory,
    /// `base` must already be aligned to at least GRANULARITY (any page-aligned
    /// region qualifies), and `init` must only be called once before any
    /// alloc/dealloc.
    pub unsafe fn init(&self, base: *mut u8, len: usize) {
        unsafe {
            // Round the usable length down to a multiple of GRANULARITY so the
            // whole-region invariant (size is always a multiple of GRANULARITY)
            // holds from the very first node onward.
            let len = len & !(GRANULARITY - 1);

            *self.base.get() = base;
            *self.len.get()  = len;

            // The whole region starts life as a single free block.
            let node = base as *mut FreeListNode;
            node.write(FreeListNode { size: len, next: None });
            *self.head.get() = Some(NonNull::new_unchecked(node));
        }
    }

    /// Bytes lost to unreclaimable slivers. Should be 0 in essentially all
    /// real kernel workloads — it only grows if an allocation requests an
    /// alignment coarser than GRANULARITY (e.g. page-aligned DMA buffers)
    /// landing at an unlucky offset. If this climbs during normal small
    /// allocations, something upstream is bypassing `adjust_layout`.
    pub fn leaked(&self) -> usize {
        unsafe { *self.leaked.get() }
    }

    pub fn total(&self) -> usize {
        unsafe { *self.len.get() }
    }

    /// Sum of all free blocks currently in the list.
    /// Not O(1) — walks the whole list.
    pub fn free(&self) -> usize {
        let mut sum = 0;
        let mut cur = unsafe { *self.head.get() };
        while let Some(node) = cur {
            let n = unsafe { node.as_ref() };
            sum += n.size;
            cur = n.next;
        }
        sum
    }

    pub fn used(&self) -> usize {
        self.total() - self.free()
    }

    /// Every allocation must be big enough and aligned enough to later hold
    /// a `FreeListNode`, since that's what gets written into it on dealloc.
    fn adjust_layout(layout: Layout) -> Layout {
        let align = layout.align().max(core::mem::align_of::<FreeListNode>());
        let size  = layout.size().max(core::mem::size_of::<FreeListNode>());
        // Round up to a multiple of GRANULARITY. Combined with base/len
        // rounding in init(), this keeps every free block's size — and, for
        // any request with align <= GRANULARITY, its address too — a clean
        // multiple of GRANULARITY. That means splits never produce a
        // remainder smaller than GRANULARITY, so nothing gets orphaned.
        let size = (size + GRANULARITY - 1) & !(GRANULARITY - 1);
        let size = if size % align == 0 {
            size
        } else {
            (size + align - 1) & !(align - 1)
        };
        Layout::from_size_align(size, align)
            .expect("adjust_layout produced invalid size/align pair")
    }

    pub fn free_node_count(&self) -> usize {
        let mut n = 0;
        let mut cur = unsafe { *self.head.get() };
        while let Some(node) = cur {
            n += 1;
            cur = unsafe { node.as_ref().next };
        }
        n
    }

    pub fn alloc_ops(&self) -> u64 {
        self.alloc_ops.load(core::sync::atomic::Ordering::Relaxed)
    }
    pub fn dealloc_ops(&self) -> u64 {
        self.dealloc_ops.load(core::sync::atomic::Ordering::Relaxed)
    }
}

unsafe impl GlobalAlloc for FreeListAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let layout = Self::adjust_layout(layout);
        let head_ptr = self.head.get();

        let mut prev: Option<NonNull<FreeListNode>> = None;
        let mut cur = unsafe { *head_ptr };

        while let Some(node_ptr) = cur {
            let node = unsafe { node_ptr.as_ref() };
            let node_addr = node_ptr.as_ptr() as usize;
            let node_size = node.size;
            let node_next = node.next;

            let aligned_addr = (node_addr + layout.align() - 1) & !(layout.align() - 1);
            let front_pad = aligned_addr - node_addr;
            let needed = front_pad + layout.size();

            if node_size >= needed {
                let back_len = node_size - needed;
                let mut next_free = node_next;

                // Leftover space *after* the allocation becomes its own free node.
                // With GRANULARITY-rounded sizes this is always 0 or >= GRANULARITY
                // in practice; the else branch only fires for pathological inputs.
                if back_len > 0 {
                    if back_len >= GRANULARITY {
                        let tail_ptr = (aligned_addr + layout.size()) as *mut FreeListNode;
                        unsafe { tail_ptr.write(FreeListNode { size: back_len, next: next_free }); }
                        next_free = Some(unsafe { NonNull::new_unchecked(tail_ptr) });
                    } else {
                        unsafe { *self.leaked.get() += back_len; }
                    }
                }

                // Leftover space *before* the allocation (from alignment padding)
                // becomes its own free node too, if it's big enough to describe.
                // Nonzero front_pad only happens when align > GRANULARITY.
                if front_pad > 0 {
                    if front_pad >= GRANULARITY {
                        let front_ptr = node_addr as *mut FreeListNode;
                        unsafe { front_ptr.write(FreeListNode { size: front_pad, next: next_free }); }
                        next_free = Some(unsafe { NonNull::new_unchecked(front_ptr) });
                    } else {
                        unsafe { *self.leaked.get() += front_pad; }
                    }
                }

                match prev {
                    Some(mut p) => unsafe { p.as_mut().next = next_free },
                    None => unsafe { *head_ptr = next_free },
                }

                return aligned_addr as *mut u8;
            }

            prev = cur;
            cur = node_next;
        }

        core::ptr::null_mut()
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        let layout = Self::adjust_layout(layout);
        let new_addr = ptr as usize;
        let new_size = layout.size();
        let head_ptr = self.head.get();

        unsafe {
            // Walk to find the sorted insertion point: prev.addr < new_addr < cur.addr
            let mut prev: Option<NonNull<FreeListNode>> = None;
            let mut cur = *head_ptr;
            while let Some(node) = cur {
                if node.as_ptr() as usize > new_addr {
                    break;
                }
                prev = cur;
                cur = node.as_ref().next;
            }

            // Does the new block glue onto the end of `prev`?
            let merged_with_prev = if let Some(mut p) = prev {
                let p_ref = p.as_mut();
                if p.as_ptr() as usize + p_ref.size == new_addr {
                    p_ref.size += new_size;
                    true
                } else {
                    false
                }
            } else {
                false
            };

            // Does `cur` glue onto the end of the new block (or the now-merged prev)?
            let absorbs_cur = match cur {
                Some(c) => {
                    let boundary = if merged_with_prev {
                        prev.unwrap().as_ref().size + prev.unwrap().as_ptr() as usize
                    } else {
                        new_addr + new_size
                    };
                    boundary == c.as_ptr() as usize
                }
                None => false,
            };

            if merged_with_prev {
                if absorbs_cur {
                    let c = cur.unwrap();
                    prev.unwrap().as_mut().size += c.as_ref().size;
                    prev.unwrap().as_mut().next = c.as_ref().next;
                }
                // else: prev already relinked correctly, nothing else to do
            } else if absorbs_cur {
                let c = cur.unwrap();
                let node_ptr = ptr as *mut FreeListNode;
                node_ptr.write(FreeListNode {
                    size: new_size + c.as_ref().size,
                    next: c.as_ref().next,
                });
                let new_node = Some(NonNull::new_unchecked(node_ptr));
                match prev {
                    Some(mut p) => p.as_mut().next = new_node,
                    None => *head_ptr = new_node,
                }
            } else {
                // No merge either side — plain sorted insert
                let node_ptr = ptr as *mut FreeListNode;
                node_ptr.write(FreeListNode { size: new_size, next: cur });
                let new_node = Some(NonNull::new_unchecked(node_ptr));
                match prev {
                    Some(mut p) => p.as_mut().next = new_node,
                    None => *head_ptr = new_node,
                }
            }
        }
    }
}