use super::ast::{BinOp, Expr, Function, Program, Stmt};
use super::lexer::{Token, TokenKind};

pub struct Parser {
    tokens: alloc::vec::Vec<Token>,
    pos: usize,
}

impl Parser {
    pub fn new(tokens: alloc::vec::Vec<Token>) -> Self {
        Self { tokens, pos: 0 }
    }

    pub fn parse_program(&mut self) -> Result<Program, alloc::string::String> {
        let mut functions = alloc::vec::Vec::new();
        while !self.check(TokenKind::Eof) {
            functions.push(self.parse_function()?);
        }
        if !functions.iter().any(|f| f.name == "main") {
            return Err(alloc::string::String::from(
                "parser error: program must define main()",
            ));
        }
        Ok(Program { functions })
    }

    fn parse_function(&mut self) -> Result<Function, alloc::string::String> {
        self.expect(TokenKind::IntKw)?;
        let name = self.expect_ident()?;
        self.expect(TokenKind::LParen)?;
        let mut params = alloc::vec::Vec::new();
        if !self.check(TokenKind::RParen) {
            loop {
                self.expect(TokenKind::IntKw)?;
                params.push(self.expect_ident()?);
                if !self.match_token(TokenKind::Comma) {
                    break;
                }
            }
        }
        self.expect(TokenKind::RParen)?;
        self.expect(TokenKind::LBrace)?;
        let mut body = alloc::vec::Vec::new();
        while !self.check(TokenKind::RBrace) {
            body.push(self.parse_stmt()?);
        }
        self.expect(TokenKind::RBrace)?;
        Ok(Function { name, params, body })
    }

    fn parse_stmt(&mut self) -> Result<Stmt, alloc::string::String> {
        if self.match_token(TokenKind::IntKw) {
            let name = self.expect_ident()?;
            let init = if self.match_token(TokenKind::Assign) {
                Some(self.parse_expr()?)
            } else {
                None
            };
            self.expect(TokenKind::Semicolon)?;
            return Ok(Stmt::Decl(name, init));
        }
        if self.match_token(TokenKind::If) {
            self.expect(TokenKind::LParen)?;
            let cond = self.parse_expr()?;
            self.expect(TokenKind::RParen)?;
            let then_body = self.parse_block()?;
            let else_body = if self.match_token(TokenKind::Else) {
                Some(self.parse_block()?)
            } else {
                None
            };
            return Ok(Stmt::If(cond, then_body, else_body));
        }
        if self.match_token(TokenKind::While) {
            self.expect(TokenKind::LParen)?;
            let cond = self.parse_expr()?;
            self.expect(TokenKind::RParen)?;
            let body = self.parse_block()?;
            return Ok(Stmt::While(cond, body));
        }
        if self.match_token(TokenKind::Return) {
            let expr = self.parse_expr()?;
            self.expect(TokenKind::Semicolon)?;
            return Ok(Stmt::Return(expr));
        }

        if let TokenKind::Ident(name) = self.peek_kind() {
            let name = name.clone();
            self.advance();
            if self.match_token(TokenKind::Assign) {
                let expr = self.parse_expr()?;
                self.expect(TokenKind::Semicolon)?;
                return Ok(Stmt::Assign(name, expr));
            }
            self.pos -= 1;
            let expr = self.parse_expr()?;
            self.expect(TokenKind::Semicolon)?;
            return Ok(Stmt::Expr(expr));
        }

        let expr = self.parse_expr()?;
        self.expect(TokenKind::Semicolon)?;
        Ok(Stmt::Expr(expr))
    }

    fn parse_block(&mut self) -> Result<alloc::vec::Vec<Stmt>, alloc::string::String> {
        self.expect(TokenKind::LBrace)?;
        let mut body = alloc::vec::Vec::new();
        while !self.check(TokenKind::RBrace) {
            body.push(self.parse_stmt()?);
        }
        self.expect(TokenKind::RBrace)?;
        Ok(body)
    }

    fn parse_expr(&mut self) -> Result<Expr, alloc::string::String> {
        self.parse_or()
    }

    fn parse_or(&mut self) -> Result<Expr, alloc::string::String> {
        let mut expr = self.parse_and()?;
        while self.match_token(TokenKind::OrOr) {
            let rhs = self.parse_and()?;
            expr = Expr::Bin(alloc::boxed::Box::new(expr), BinOp::Or, alloc::boxed::Box::new(rhs));
        }
        Ok(expr)
    }

    fn parse_and(&mut self) -> Result<Expr, alloc::string::String> {
        let mut expr = self.parse_equality()?;
        while self.match_token(TokenKind::AndAnd) {
            let rhs = self.parse_equality()?;
            expr = Expr::Bin(alloc::boxed::Box::new(expr), BinOp::And, alloc::boxed::Box::new(rhs));
        }
        Ok(expr)
    }

    fn parse_equality(&mut self) -> Result<Expr, alloc::string::String> {
        let mut expr = self.parse_comparison()?;
        loop {
            let op = if self.match_token(TokenKind::EqEq) {
                BinOp::Eq
            } else if self.match_token(TokenKind::Ne) {
                BinOp::Ne
            } else {
                break;
            };
            let rhs = self.parse_comparison()?;
            expr = Expr::Bin(alloc::boxed::Box::new(expr), op, alloc::boxed::Box::new(rhs));
        }
        Ok(expr)
    }

    fn parse_comparison(&mut self) -> Result<Expr, alloc::string::String> {
        let mut expr = self.parse_term()?;
        loop {
            let op = if self.match_token(TokenKind::Lt) {
                BinOp::Lt
            } else if self.match_token(TokenKind::Le) {
                BinOp::Le
            } else if self.match_token(TokenKind::Gt) {
                BinOp::Gt
            } else if self.match_token(TokenKind::Ge) {
                BinOp::Ge
            } else {
                break;
            };
            let rhs = self.parse_term()?;
            expr = Expr::Bin(alloc::boxed::Box::new(expr), op, alloc::boxed::Box::new(rhs));
        }
        Ok(expr)
    }

    fn parse_term(&mut self) -> Result<Expr, alloc::string::String> {
        let mut expr = self.parse_factor()?;
        loop {
            let op = if self.match_token(TokenKind::Plus) {
                BinOp::Add
            } else if self.match_token(TokenKind::Minus) {
                BinOp::Sub
            } else {
                break;
            };
            let rhs = self.parse_factor()?;
            expr = Expr::Bin(alloc::boxed::Box::new(expr), op, alloc::boxed::Box::new(rhs));
        }
        Ok(expr)
    }

    fn parse_factor(&mut self) -> Result<Expr, alloc::string::String> {
        let mut expr = self.parse_unary()?;
        loop {
            let op = if self.match_token(TokenKind::Star) {
                BinOp::Mul
            } else if self.match_token(TokenKind::Slash) {
                BinOp::Div
            } else if self.match_token(TokenKind::Percent) {
                BinOp::Mod
            } else {
                break;
            };
            let rhs = self.parse_unary()?;
            expr = Expr::Bin(alloc::boxed::Box::new(expr), op, alloc::boxed::Box::new(rhs));
        }
        Ok(expr)
    }

    fn parse_unary(&mut self) -> Result<Expr, alloc::string::String> {
        if self.match_token(TokenKind::Bang) {
            return Ok(Expr::UnaryNot(alloc::boxed::Box::new(self.parse_unary()?)));
        }
        if self.match_token(TokenKind::Minus) {
            return Ok(Expr::UnaryNeg(alloc::boxed::Box::new(self.parse_unary()?)));
        }
        self.parse_primary()
    }

    fn parse_primary(&mut self) -> Result<Expr, alloc::string::String> {
        if let TokenKind::Int(value) = self.peek_kind() {
            self.advance();
            return Ok(Expr::Int(value));
        }
        if let TokenKind::Ident(name) = self.peek_kind() {
            let name = name.clone();
            self.advance();
            if self.match_token(TokenKind::LParen) {
                let mut args = alloc::vec::Vec::new();
                if !self.check(TokenKind::RParen) {
                    loop {
                        args.push(self.parse_expr()?);
                        if !self.match_token(TokenKind::Comma) {
                            break;
                        }
                    }
                }
                self.expect(TokenKind::RParen)?;
                return Ok(Expr::Call(name, args));
            }
            return Ok(Expr::Var(name));
        }
        if self.match_token(TokenKind::LParen) {
            let expr = self.parse_expr()?;
            self.expect(TokenKind::RParen)?;
            return Ok(expr);
        }
        Err(self.error("expected expression"))
    }

    fn expect_ident(&mut self) -> Result<alloc::string::String, alloc::string::String> {
        if let TokenKind::Ident(name) = self.peek_kind() {
            let name = name.clone();
            self.advance();
            Ok(name)
        } else {
            Err(self.error("expected identifier"))
        }
    }

    fn expect(&mut self, kind: TokenKind) -> Result<(), alloc::string::String> {
        if self.match_token(kind.clone()) {
            Ok(())
        } else {
            Err(self.error(&alloc::format!("expected {kind:?}")))
        }
    }

    fn match_token(&mut self, kind: TokenKind) -> bool {
        if self.check(kind.clone()) {
            self.advance();
            true
        } else {
            false
        }
    }

    fn check(&self, kind: TokenKind) -> bool {
        self.peek_kind() == kind
    }

    fn peek_kind(&self) -> TokenKind {
        self.tokens
            .get(self.pos)
            .map(|token| token.kind.clone())
            .unwrap_or(TokenKind::Eof)
    }

    fn advance(&mut self) {
        if self.pos < self.tokens.len() {
            self.pos += 1;
        }
    }

    fn error(&self, msg: &str) -> alloc::string::String {
        let line = self
            .tokens
            .get(self.pos.saturating_sub(1))
            .map(|token| token.line)
            .unwrap_or(1);
        alloc::format!("parser error at line {line}: {msg}")
    }
}