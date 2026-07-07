use alloc::boxed::Box;

#[derive(Clone, Debug, PartialEq)]
pub enum BinOp {
    Add,
    Sub,
    Mul,
    Div,
    Mod,
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
    And,
    Or,
}

#[derive(Clone, Debug)]
pub enum Expr {
    Int(i32),
    Var(alloc::string::String),
    UnaryNot(Box<Expr>),
    UnaryNeg(Box<Expr>),
    Bin(Box<Expr>, BinOp, Box<Expr>),
    Call(alloc::string::String, alloc::vec::Vec<Expr>),
}

#[derive(Clone, Debug)]
pub enum Stmt {
    Decl(alloc::string::String, Option<Expr>),
    Assign(alloc::string::String, Expr),
    If(Expr, alloc::vec::Vec<Stmt>, Option<alloc::vec::Vec<Stmt>>),
    While(Expr, alloc::vec::Vec<Stmt>),
    Return(Expr),
    Expr(Expr),
}

#[derive(Clone, Debug)]
pub struct Function {
    pub name: alloc::string::String,
    pub params: alloc::vec::Vec<alloc::string::String>,
    pub body: alloc::vec::Vec<Stmt>,
}

#[derive(Clone, Debug)]
pub struct Program {
    pub functions: alloc::vec::Vec<Function>,
}