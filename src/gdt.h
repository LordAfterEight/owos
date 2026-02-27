#include <stdint.h>

#define SEG_DESCTYPE(x)  ((x) << 0x04)
#define SEG_PRES(x)      ((x) << 0x07)
#define SEG_SAVL(x)      ((x) << 0x0C)
#define SEG_LONG(x)      ((x) << 0x0D)
#define SEG_SIZE(x)      ((x) << 0x0E)
#define SEG_GRAN(x)      ((x) << 0x0F)
#define SEG_PRIV(x)     (((x) &  0x03) << 0x05)

#define SEG_DATA_RD        0x00
#define SEG_DATA_RDA       0x01
#define SEG_DATA_RDWR      0x02
#define SEG_DATA_RDWRA     0x03
#define SEG_DATA_RDEXPD    0x04
#define SEG_DATA_RDEXPDA   0x05
#define SEG_DATA_RDWREXPD  0x06
#define SEG_DATA_RDWREXPDA 0x07
#define SEG_CODE_EX        0x08
#define SEG_CODE_EXA       0x09
#define SEG_CODE_EXRD      0x0A
#define SEG_CODE_EXRDA     0x0B
#define SEG_CODE_EXC       0x0C
#define SEG_CODE_EXCA      0x0D
#define SEG_CODE_EXRDC     0x0E
#define SEG_CODE_EXRDCA    0x0F

#define GDT_CODE_PL0 SEG_DESCTYPE(1) | SEG_PRES(1) | SEG_SAVL(0) | \
SEG_LONG(0)     | SEG_SIZE(1) | SEG_GRAN(1) | \
SEG_PRIV(0)     | SEG_CODE_EXRD

#define GDT_DATA_PL0 SEG_DESCTYPE(1) | SEG_PRES(1) | SEG_SAVL(0) | \
SEG_LONG(0)     | SEG_SIZE(1) | SEG_GRAN(1) | \
SEG_PRIV(0)     | SEG_DATA_RDWR

#define GDT_CODE_PL3 SEG_DESCTYPE(1) | SEG_PRES(1) | SEG_SAVL(0) | \
SEG_LONG(0)     | SEG_SIZE(1) | SEG_GRAN(1) | \
SEG_PRIV(3)     | SEG_CODE_EXRD

#define GDT_DATA_PL3 SEG_DESCTYPE(1) | SEG_PRES(1) | SEG_SAVL(0) | \
SEG_LONG(0)     | SEG_SIZE(1) | SEG_GRAN(1) | \
SEG_PRIV(3)     | SEG_DATA_RDWR

struct __attribute__((packed)) TSS64 {
    uint32_t reserved0;
    uint64_t rsp0;
    uint64_t rsp1;
    uint64_t rsp2;
    uint64_t reserved1;
    uint64_t ist1;
    uint64_t ist2;
    uint64_t ist3;
    uint64_t ist4;
    uint64_t ist5;
    uint64_t ist6;
    uint64_t ist7;
    uint64_t reserved2;
    uint16_t reserved3;
    uint16_t iomap_base;
};

static uint64_t gdt[7] __attribute__((aligned(16)));
static struct TSS64 tss __attribute__((aligned(16)));
static uint8_t double_fault_stack[4096 * 4] __attribute__((aligned(16)));

void create_descriptor(uint32_t base, uint32_t limit, uint16_t flag);
void gdt_init(void);
void tss_set_rsp0(uint64_t rsp0);
