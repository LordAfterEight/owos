mod ast;
mod codegen;
mod lexer;
mod parser;
pub mod runtime;

pub use codegen::{compile, Executable};

pub fn compile_source(source: &str) -> Result<Executable, alloc::string::String> {
    let tokens = lexer::Lexer::new(source).tokenize()?;
    let mut parser = parser::Parser::new(tokens);
    let program = parser.parse_program()?;
    compile(&program)
}
