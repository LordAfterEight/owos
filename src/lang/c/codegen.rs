use super::ast::{BinOp, Expr, Function, Program, Stmt};
use alloc::collections::BTreeMap;

pub struct Executable {
    pub code: alloc::vec::Vec<u8>,
    pub entry: usize,
}

impl Executable {
    pub fn to_bytes(&self) -> alloc::vec::Vec<u8> {
        let mut out = alloc::vec::Vec::with_capacity(8 + self.code.len());
        out.extend_from_slice(&(self.entry as u64).to_le_bytes());
        out.extend_from_slice(&self.code);
        out
    }

    pub fn from_bytes(bytes: &[u8]) -> Result<Self, alloc::string::String> {
        if bytes.len() < 8 {
            return Err(alloc::string::String::from(
                "runtime error: executable too small",
            ));
        }
        let entry = u64::from_le_bytes(bytes[0..8].try_into().unwrap()) as usize;
        let code = bytes[8..].to_vec();
        if entry >= code.len() {
            return Err(alloc::string::String::from(
                "runtime error: invalid executable entry",
            ));
        }
        Ok(Self { code, entry })
    }
}

struct Emitter {
    code: alloc::vec::Vec<u8>,
    fixups: alloc::vec::Vec<(usize, alloc::string::String)>,
}

impl Emitter {
    fn new() -> Self {
        Self {
            code: alloc::vec::Vec::new(),
            fixups: alloc::vec::Vec::new(),
        }
    }

    fn emit(&mut self, bytes: &[u8]) {
        self.code.extend_from_slice(bytes);
    }

    fn emit_u8(&mut self, value: u8) {
        self.code.push(value);
    }

    fn emit_u32(&mut self, value: u32) {
        self.code.extend_from_slice(&value.to_le_bytes());
    }

    fn emit_i32(&mut self, value: i32) {
        self.code.extend_from_slice(&value.to_le_bytes());
    }

    fn emit_i64(&mut self, value: i64) {
        self.code.extend_from_slice(&value.to_le_bytes());
    }

    fn here(&self) -> usize {
        self.code.len()
    }

    fn call_rel32(&mut self, target: &str) {
        self.emit(&[0xE8]);
        self.fixups.push((self.here(), alloc::string::String::from(target)));
        self.emit_u32(0);
    }

    fn patch_jmp(&mut self, site: usize, target: usize) {
        let rel = (target as i64 - (site as i64 + 4)) as i32;
        self.code[site..site + 4].copy_from_slice(&rel.to_le_bytes());
    }

    fn jmp_if_zero(&mut self, target: usize) {
        self.emit(&[0x48, 0x85, 0xC0]);
        self.emit(&[0x0F, 0x84]);
        let site = self.here();
        let rel = (target as i64 - (site as i64 + 4)) as i32;
        self.emit_i32(rel);
    }

    fn jmp(&mut self, target: usize) {
        self.emit(&[0xE9]);
        let site = self.here();
        let rel = (target as i64 - (site as i64 + 4)) as i32;
        self.emit_i32(rel);
    }

    fn push_rax(&mut self) {
        self.emit(&[0x50]);
    }

    fn pop_rbx(&mut self) {
        self.emit(&[0x5B]);
    }

    fn mov_rax_imm32(&mut self, value: i32) {
        self.emit(&[0x48, 0xC7, 0xC0]);
        self.emit_i32(value);
    }

    fn mov_rax_from_slot(&mut self, slot: i32) {
        let disp = (-8 * (slot + 1)) as i8 as u8;
        self.emit(&[0x48, 0x8B, 0x45, disp]);
    }

    fn mov_slot_from_rax(&mut self, slot: i32) {
        let disp = (-8 * (slot + 1)) as i8 as u8;
        self.emit(&[0x48, 0x89, 0x45, disp]);
    }

    fn mov_rdi_from_rax(&mut self) {
        self.emit(&[0x48, 0x89, 0xC7]);
    }

    fn mov_rsi_from_rax(&mut self) {
        self.emit(&[0x48, 0x89, 0xC6]);
    }

    fn mov_rdx_from_rax(&mut self) {
        self.emit(&[0x48, 0x89, 0xC2]);
    }

    fn add_rax_rbx(&mut self) {
        self.emit(&[0x48, 0x01, 0xD8]);
    }

    fn sub_rax_rbx(&mut self) {
        self.emit(&[0x48, 0x29, 0xD8]);
    }

    fn imul_rax_rbx(&mut self) {
        self.emit(&[0x48, 0x0F, 0xAF, 0xC3]);
    }

    fn neg_rax(&mut self) {
        self.emit(&[0x48, 0xF7, 0xD8]);
    }

    fn xor_rax_rax(&mut self) {
        self.emit(&[0x48, 0x31, 0xC0]);
    }

    fn xor_rcx_rcx(&mut self) {
        self.emit(&[0x48, 0x31, 0xC9]);
    }

    fn cmp_rax_rbx(&mut self) {
        self.emit(&[0x48, 0x39, 0xD8]);
    }

    fn setcc_al(&mut self, cc: u8) {
        self.emit(&[0x0F, 0x94, cc]);
    }

    fn movzx_rax_al(&mut self) {
        self.emit(&[0x48, 0x0F, 0xB6, 0xC0]);
    }

    fn mov_rcx_rax(&mut self) {
        self.emit(&[0x48, 0x89, 0xC1]);
    }

    fn idiv_rbx(&mut self) {
        self.emit(&[0x48, 0xF7, 0xFB]);
    }

    fn cqo(&mut self) {
        self.emit(&[0x48, 0x99]);
    }

    fn mov_rax_rdx(&mut self) {
        self.emit(&[0x48, 0x89, 0xD0]);
    }

    fn call_abs(&mut self, addr: u64) {
        self.emit(&[0x48, 0xB8]);
        self.emit_i64(addr as i64);
        self.emit(&[0xFF, 0xD0]);
    }

    fn prologue(&mut self, stack_bytes: u32) {
        self.emit(&[0x55]);
        self.emit(&[0x48, 0x89, 0xE5]);
        if stack_bytes > 0 {
            if stack_bytes <= 127 {
                self.emit(&[0x48, 0x83, 0xEC, stack_bytes as u8]);
            } else {
                self.emit(&[0x48, 0x81, 0xEC]);
                self.emit_u32(stack_bytes);
            }
        }
    }

    fn epilogue_ret(&mut self) {
        self.emit(&[0x48, 0x89, 0xEC]);
        self.emit(&[0x5D]);
        self.emit(&[0xC3]);
    }
}

struct FuncGen<'a> {
    emitter: &'a mut Emitter,
    slots: BTreeMap<alloc::string::String, i32>,
    next_slot: i32,
}

impl<'a> FuncGen<'a> {
    fn new(emitter: &'a mut Emitter) -> Self {
        Self {
            emitter,
            slots: BTreeMap::new(),
            next_slot: 0,
        }
    }

    fn alloc_slot(&mut self, name: alloc::string::String) -> i32 {
        let slot = self.next_slot;
        self.next_slot += 1;
        self.slots.insert(name, slot);
        slot
    }

    fn lookup_slot(&self, name: &str) -> Option<i32> {
        self.slots.get(name).copied()
    }

    fn stack_bytes(&self) -> u32 {
        let bytes = (self.next_slot as u32) * 8;
        let aligned = (bytes + 15) & !15;
        aligned.max(16)
    }

    fn gen_stmt_v2(&mut self, stmt: &Stmt) -> Result<(), alloc::string::String> {
        match stmt {
            Stmt::Decl(name, init) => {
                let slot = self.alloc_slot(name.clone());
                if let Some(expr) = init {
                    self.gen_expr(expr)?;
                } else {
                    self.emitter.xor_rax_rax();
                }
                self.emitter.mov_slot_from_rax(slot);
            }
            Stmt::Assign(name, expr) => {
                let slot = self
                    .lookup_slot(name)
                    .ok_or_else(|| alloc::format!("codegen error: unknown variable {name}"))?;
                self.gen_expr(expr)?;
                self.emitter.mov_slot_from_rax(slot);
            }
            Stmt::If(cond, then_body, else_body) => {
                self.gen_expr(cond)?;
                self.emitter.emit(&[0x48, 0x85, 0xC0]);
                self.emitter.emit(&[0x0F, 0x84]);
                let false_fixup = self.emitter.here();
                self.emitter.emit_u32(0);
                for s in then_body {
                    self.gen_stmt_v2(s)?;
                }
                if let Some(else_stmts) = else_body {
                    self.emitter.emit(&[0xE9]);
                    let end_fixup = self.emitter.here();
                    self.emitter.emit_u32(0);
                    let else_pos = self.emitter.here();
                    self.emitter.patch_jmp(false_fixup, else_pos);
                    for s in else_stmts {
                        self.gen_stmt_v2(s)?;
                    }
                    let end_pos = self.emitter.here();
                    self.emitter.patch_jmp(end_fixup, end_pos);
                } else {
                    let end_pos = self.emitter.here();
                    self.emitter.patch_jmp(false_fixup, end_pos);
                }
            }
            Stmt::While(cond, body) => {
                let loop_start = self.emitter.here();
                self.gen_expr(cond)?;
                self.emitter.emit(&[0x48, 0x85, 0xC0]);
                self.emitter.emit(&[0x0F, 0x84]);
                let exit_fixup = self.emitter.here();
                self.emitter.emit_u32(0);
                for s in body {
                    self.gen_stmt_v2(s)?;
                }
                self.emitter.jmp(loop_start);
                let exit_pos = self.emitter.here();
                self.emitter.patch_jmp(exit_fixup, exit_pos);
            }
            Stmt::Return(expr) => {
                self.gen_expr(expr)?;
                self.emitter.epilogue_ret();
            }
            Stmt::Expr(expr) => {
                self.gen_expr(expr)?;
            }
        }
        Ok(())
    }

    fn gen_expr(&mut self, expr: &Expr) -> Result<(), alloc::string::String> {
        match expr {
            Expr::Int(value) => self.emitter.mov_rax_imm32(*value),
            Expr::Var(name) => {
                let slot = self
                    .lookup_slot(name)
                    .ok_or_else(|| alloc::format!("codegen error: unknown variable {name}"))?;
                self.emitter.mov_rax_from_slot(slot);
            }
            Expr::UnaryNot(inner) => {
                self.gen_expr(inner)?;
                self.emitter.emit(&[0x48, 0x85, 0xC0]);
                self.emitter.xor_rcx_rcx();
                self.emitter.setcc_al(0x94); // sete
                self.emitter.movzx_rax_al();
            }
            Expr::UnaryNeg(inner) => {
                self.gen_expr(inner)?;
                self.emitter.neg_rax();
            }
            Expr::Bin(lhs, op, rhs) => match op {
                BinOp::And => {
                    self.gen_expr(lhs)?;
                    self.emitter.emit(&[0x48, 0x85, 0xC0]);
                    self.emitter.emit(&[0x0F, 0x84]);
                    let fix = self.emitter.here();
                    self.emitter.emit_u32(0);
                    self.gen_expr(rhs)?;
                    let end = self.emitter.here();
                    self.emitter.patch_jmp(fix, end);
                }
                BinOp::Or => {
                    self.gen_expr(lhs)?;
                    self.emitter.emit(&[0x48, 0x85, 0xC0]);
                    self.emitter.emit(&[0x0F, 0x85]);
                    let fix = self.emitter.here();
                    self.emitter.emit_u32(0);
                    self.gen_expr(rhs)?;
                    let end = self.emitter.here();
                    self.emitter.patch_jmp(fix, end);
                }
                _ => {
                    self.gen_expr(rhs)?;
                    self.emitter.push_rax();
                    self.gen_expr(lhs)?;
                    self.emitter.pop_rbx();
                    match op {
                        BinOp::Add => self.emitter.add_rax_rbx(),
                        BinOp::Sub => self.emitter.sub_rax_rbx(),
                        BinOp::Mul => self.emitter.imul_rax_rbx(),
                        BinOp::Div => {
                            self.emitter.cqo();
                            self.emitter.idiv_rbx();
                        }
                        BinOp::Mod => {
                            self.emitter.cqo();
                            self.emitter.idiv_rbx();
                            self.emitter.mov_rax_rdx();
                        }
                        BinOp::Eq => {
                            self.emitter.cmp_rax_rbx();
                            self.emitter.xor_rcx_rcx();
                            self.emitter.setcc_al(0x94);
                            self.emitter.movzx_rax_al();
                        }
                        BinOp::Ne => {
                            self.emitter.cmp_rax_rbx();
                            self.emitter.xor_rcx_rcx();
                            self.emitter.setcc_al(0x95);
                            self.emitter.movzx_rax_al();
                        }
                        BinOp::Lt => {
                            self.emitter.cmp_rax_rbx();
                            self.emitter.xor_rcx_rcx();
                            self.emitter.setcc_al(0x9C);
                            self.emitter.movzx_rax_al();
                        }
                        BinOp::Le => {
                            self.emitter.cmp_rax_rbx();
                            self.emitter.xor_rcx_rcx();
                            self.emitter.setcc_al(0x9E);
                            self.emitter.movzx_rax_al();
                        }
                        BinOp::Gt => {
                            self.emitter.cmp_rax_rbx();
                            self.emitter.xor_rcx_rcx();
                            self.emitter.setcc_al(0x9F);
                            self.emitter.movzx_rax_al();
                        }
                        BinOp::Ge => {
                            self.emitter.cmp_rax_rbx();
                            self.emitter.xor_rcx_rcx();
                            self.emitter.setcc_al(0x9D);
                            self.emitter.movzx_rax_al();
                        }
                        BinOp::And | BinOp::Or => unreachable!(),
                    }
                }
            },
            Expr::Call(name, args) => {
                if args.len() > 3 {
                    return Err(alloc::string::String::from(
                        "codegen error: at most 3 arguments supported",
                    ));
                }
                for (index, arg) in args.iter().enumerate() {
                    self.gen_expr(arg)?;
                    match index {
                        0 => self.emitter.mov_rdi_from_rax(),
                        1 => self.emitter.mov_rsi_from_rax(),
                        2 => self.emitter.mov_rdx_from_rax(),
                        _ => {}
                    }
                }
                if name == "print_int" {
                    self.emitter
                        .call_abs(super::runtime::print_int as *const () as usize as u64);
                } else {
                    self.emitter.call_rel32(name);
                }
            }
        }
        Ok(())
    }
}

pub fn compile(program: &Program) -> Result<Executable, alloc::string::String> {
    let mut emitter = Emitter::new();
    let mut func_addrs = BTreeMap::<alloc::string::String, usize>::new();

    for function in &program.functions {
        func_addrs.insert(function.name.clone(), emitter.here());
        let mut func_gen = FuncGen::new(&mut emitter);
        func_gen.generate_function_v2(function)?;
    }

    let entry = *func_addrs
        .get("main")
        .ok_or_else(|| alloc::string::String::from("codegen error: missing main"))?;

    for (site, target) in &emitter.fixups {
        let addr = func_addrs
            .get(target)
            .ok_or_else(|| alloc::format!("codegen error: unknown function {target}"))?;
        let rel = (*addr as i64 - (*site as i64 + 4)) as i32;
        emitter.code[*site..*site + 4].copy_from_slice(&rel.to_le_bytes());
    }

    Ok(Executable {
        code: emitter.code,
        entry,
    })
}

impl<'a> FuncGen<'a> {
    fn generate_function_v2(&mut self, function: &Function) -> Result<(), alloc::string::String> {
        for (index, param) in function.params.iter().enumerate() {
            self.slots.insert(param.clone(), index as i32);
            self.next_slot = self.next_slot.max(index as i32 + 1);
        }

        let stack_bytes = self.stack_bytes();
        self.emitter.prologue(stack_bytes);

        if !function.params.is_empty() {
            self.emitter.mov_slot_from_rax(0);
        }
        if function.params.len() > 1 {
            self.emitter.emit(&[0x48, 0x89, 0xF0]);
            self.emitter.mov_slot_from_rax(1);
        }
        if function.params.len() > 2 {
            self.emitter.emit(&[0x48, 0x89, 0xD0]);
            self.emitter.mov_slot_from_rax(2);
        }

        let mut has_return = false;
        for stmt in &function.body {
            if matches!(stmt, Stmt::Return(_)) {
                has_return = true;
            }
            self.gen_stmt_v2(stmt)?;
        }

        if !has_return {
            self.emitter.xor_rax_rax();
            self.emitter.epilogue_ret();
        }
        Ok(())
    }
}