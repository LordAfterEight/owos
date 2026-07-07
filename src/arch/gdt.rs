use core::mem::size_of;
use x86_64::instructions::segmentation::{Segment, CS};
use x86_64::instructions::tables::load_tss;
use x86_64::registers::segmentation::SS;
use x86_64::structures::gdt::{Descriptor, GlobalDescriptorTable, SegmentSelector};
use x86_64::structures::tss::TaskStateSegment;
use x86_64::VirtAddr;

static mut IST_STACK: [u8; 4096] = [0; 4096];
static mut TSS: TaskStateSegment = TaskStateSegment::new();

struct GdtTables {
    gdt: GlobalDescriptorTable,
    code: SegmentSelector,
    data: SegmentSelector,
    tss: SegmentSelector,
}

static GDT: spin::Once<GdtTables> = spin::Once::new();

pub fn init() {
    unsafe {
        let tss = &mut *core::ptr::addr_of_mut!(TSS);
        let ist_stack = &mut *core::ptr::addr_of_mut!(IST_STACK);
        tss.interrupt_stack_table[0] = VirtAddr::from_ptr(
            ist_stack.as_ptr().add(size_of::<[u8; 4096]>()),
        );
    }

    GDT.call_once(|| {
        let mut gdt = GlobalDescriptorTable::new();
        let code = gdt.append(Descriptor::kernel_code_segment());
        let data = gdt.append(Descriptor::kernel_data_segment());
        let tss = gdt.append(Descriptor::tss_segment(unsafe {
            &*core::ptr::addr_of_mut!(TSS)
        }));

        GdtTables {
            gdt,
            code,
            data,
            tss,
        }
    });

    let tables = GDT.get().expect("GDT not initialized");
    tables.gdt.load();
    unsafe {
        CS::set_reg(tables.code);
        SS::set_reg(tables.data);
        load_tss(tables.tss);
    }
}