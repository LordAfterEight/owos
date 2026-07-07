use x86_64::structures::idt::InterruptDescriptorTable;
use x86_64::VirtAddr;

static mut IDT: InterruptDescriptorTable = InterruptDescriptorTable::new();

pub fn init() {
    unsafe {
        let idt = &mut *core::ptr::addr_of_mut!(IDT);
        idt.divide_error
            .set_handler_addr(VirtAddr::new(crate::arch::isr::handler_addr(0)));
        idt.debug
            .set_handler_addr(VirtAddr::new(crate::arch::isr::handler_addr(1)));
        idt.non_maskable_interrupt
            .set_handler_addr(VirtAddr::new(crate::arch::isr::handler_addr(2)));
        idt.breakpoint
            .set_handler_addr(VirtAddr::new(crate::arch::isr::handler_addr(3)));
        idt.overflow
            .set_handler_addr(VirtAddr::new(crate::arch::isr::handler_addr(4)));
        idt.bound_range_exceeded
            .set_handler_addr(VirtAddr::new(crate::arch::isr::handler_addr(5)));
        idt.invalid_opcode
            .set_handler_addr(VirtAddr::new(crate::arch::isr::handler_addr(6)));
        idt.device_not_available
            .set_handler_addr(VirtAddr::new(crate::arch::isr::handler_addr(7)));
        idt.double_fault
            .set_handler_addr(VirtAddr::new(crate::arch::isr::handler_addr(8)))
            .set_stack_index(0);
        idt.invalid_tss
            .set_handler_addr(VirtAddr::new(crate::arch::isr::handler_addr(10)));
        idt.segment_not_present
            .set_handler_addr(VirtAddr::new(crate::arch::isr::handler_addr(11)));
        idt.stack_segment_fault
            .set_handler_addr(VirtAddr::new(crate::arch::isr::handler_addr(12)));
        idt.general_protection_fault
            .set_handler_addr(VirtAddr::new(crate::arch::isr::handler_addr(13)));
        idt.page_fault
            .set_handler_addr(VirtAddr::new(crate::arch::isr::handler_addr(14)));
        idt.x87_floating_point
            .set_handler_addr(VirtAddr::new(crate::arch::isr::handler_addr(16)));
        idt.alignment_check
            .set_handler_addr(VirtAddr::new(crate::arch::isr::handler_addr(17)));
        idt.machine_check
            .set_handler_addr(VirtAddr::new(crate::arch::isr::handler_addr(18)));
        idt.simd_floating_point
            .set_handler_addr(VirtAddr::new(crate::arch::isr::handler_addr(19)));
        idt.virtualization
            .set_handler_addr(VirtAddr::new(crate::arch::isr::handler_addr(20)));
        idt.security_exception
            .set_handler_addr(VirtAddr::new(crate::arch::isr::handler_addr(30)));
        idt[crate::arch::pic::PIC1_OFFSET]
            .set_handler_addr(VirtAddr::new(crate::arch::isr::handler_addr(32)));

        idt.load();
    }
}