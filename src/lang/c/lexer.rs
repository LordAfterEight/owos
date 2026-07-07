#[derive(Clone, Debug, PartialEq)]
pub enum TokenKind {
    Int(i32),
    Ident(alloc::string::String),
    IntKw,
    If,
    Else,
    While,
    Return,
    LParen,
    RParen,
    LBrace,
    RBrace,
    Semicolon,
    Comma,
    Assign,
    Plus,
    Minus,
    Star,
    Slash,
    Percent,
    Bang,
    EqEq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
    AndAnd,
    OrOr,
    Eof,
}

#[derive(Clone, Debug)]
pub struct Token {
    pub kind: TokenKind,
    pub line: u32,
}

pub struct Lexer<'a> {
    src: &'a str,
    chars: alloc::vec::Vec<char>,
    pos: usize,
    line: u32,
}

impl<'a> Lexer<'a> {
    pub fn new(src: &'a str) -> Self {
        Self {
            src,
            chars: src.chars().collect(),
            pos: 0,
            line: 1,
        }
    }

    pub fn tokenize(mut self) -> Result<alloc::vec::Vec<Token>, alloc::string::String> {
        let mut tokens = alloc::vec::Vec::new();
        loop {
            let token = self.next_token()?;
            let done = token.kind == TokenKind::Eof;
            tokens.push(token);
            if done {
                break;
            }
        }
        Ok(tokens)
    }

    fn next_token(&mut self) -> Result<Token, alloc::string::String> {
        self.skip_space();
        let line = self.line;
        let ch = match self.peek() {
            Some(c) => c,
            None => {
                return Ok(Token {
                    kind: TokenKind::Eof,
                    line,
                });
            }
        };

        if ch.is_ascii_digit() {
            return Ok(Token {
                kind: TokenKind::Int(self.read_int()?),
                line,
            });
        }

        if ch.is_ascii_alphabetic() || ch == '_' {
            let ident = self.read_ident();
            let kind = match ident.as_str() {
                "int" => TokenKind::IntKw,
                "if" => TokenKind::If,
                "else" => TokenKind::Else,
                "while" => TokenKind::While,
                "return" => TokenKind::Return,
                _ => TokenKind::Ident(ident),
            };
            return Ok(Token { kind, line });
        }

        self.advance();
        let kind = match ch {
            '(' => TokenKind::LParen,
            ')' => TokenKind::RParen,
            '{' => TokenKind::LBrace,
            '}' => TokenKind::RBrace,
            ';' => TokenKind::Semicolon,
            ',' => TokenKind::Comma,
            '+' => TokenKind::Plus,
            '-' => TokenKind::Minus,
            '*' => TokenKind::Star,
            '/' => {
                if self.peek() == Some('/') {
                    self.skip_line_comment();
                    return self.next_token();
                }
                TokenKind::Slash
            }
            '%' => TokenKind::Percent,
            '!' => {
                if self.peek() == Some('=') {
                    self.advance();
                    TokenKind::Ne
                } else {
                    TokenKind::Bang
                }
            }
            '=' => {
                if self.peek() == Some('=') {
                    self.advance();
                    TokenKind::EqEq
                } else {
                    TokenKind::Assign
                }
            }
            '<' => {
                if self.peek() == Some('=') {
                    self.advance();
                    TokenKind::Le
                } else {
                    TokenKind::Lt
                }
            }
            '>' => {
                if self.peek() == Some('=') {
                    self.advance();
                    TokenKind::Ge
                } else {
                    TokenKind::Gt
                }
            }
            '&' => {
                if self.peek() == Some('&') {
                    self.advance();
                    TokenKind::AndAnd
                } else {
                    return Err(self.error("unexpected '&'"));
                }
            }
            '|' => {
                if self.peek() == Some('|') {
                    self.advance();
                    TokenKind::OrOr
                } else {
                    return Err(self.error("unexpected '|'"));
                }
            }
            _ => return Err(self.error("unexpected character")),
        };
        Ok(Token { kind, line })
    }

    fn read_int(&mut self) -> Result<i32, alloc::string::String> {
        let start = self.pos;
        while matches!(self.peek(), Some(c) if c.is_ascii_digit()) {
            self.advance();
        }
        let text: alloc::string::String = self.chars[start..self.pos].iter().collect();
        text.parse::<i32>()
            .map_err(|_| self.error("invalid integer literal"))
    }

    fn read_ident(&mut self) -> alloc::string::String {
        let start = self.pos;
        while matches!(self.peek(), Some(c) if c.is_ascii_alphanumeric() || c == '_') {
            self.advance();
        }
        self.chars[start..self.pos].iter().collect()
    }

    fn skip_space(&mut self) {
        while let Some(ch) = self.peek() {
            match ch {
                ' ' | '\t' | '\r' => self.advance(),
                '\n' => {
                    self.advance();
                    self.line += 1;
                }
                _ => break,
            }
        }
    }

    fn skip_line_comment(&mut self) {
        while let Some(ch) = self.peek() {
            if ch == '\n' {
                break;
            }
            self.advance();
        }
    }

    fn peek(&self) -> Option<char> {
        self.chars.get(self.pos).copied()
    }

    fn advance(&mut self) {
        self.pos += 1;
    }

    fn error(&self, msg: &str) -> alloc::string::String {
        alloc::format!("lexer error at line {}: {msg}", self.line)
    }
}