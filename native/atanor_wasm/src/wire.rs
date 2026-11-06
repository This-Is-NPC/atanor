//! Plain data exchanged with Elixir for host calls: the arguments of a
//! guest's import and the reply, as terms without structs.

use rustler::{Binary, Decoder, Encoder, Env, NifResult, Term, TermType};

#[derive(Debug, Clone, PartialEq)]
pub enum Wire {
    Nil,
    Int(i64),
    Float(f64),
    /// Text or bytes: a binary on the Elixir side.
    Bin(Vec<u8>),
    Atom(String),
    List(Vec<Wire>),
    Tuple(Vec<Wire>),
}

impl Wire {
    pub fn text(s: impl AsRef<str>) -> Wire {
        Wire::Bin(s.as_ref().as_bytes().to_vec())
    }

    pub fn atom(s: &str) -> Wire {
        Wire::Atom(s.to_string())
    }
}

impl Encoder for Wire {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self {
            Wire::Nil => rustler::types::atom::nil().encode(env),
            Wire::Int(i) => i.encode(env),
            Wire::Float(f) => f.encode(env),
            Wire::Bin(b) => {
                let mut bin = rustler::NewBinary::new(env, b.len());
                bin.as_mut_slice().copy_from_slice(b);
                Binary::from(bin).encode(env)
            }
            Wire::Atom(a) => rustler::Atom::from_str(env, a).unwrap().encode(env),
            Wire::List(items) => items
                .iter()
                .map(|i| i.encode(env))
                .collect::<Vec<_>>()
                .encode(env),
            Wire::Tuple(items) => rustler::types::tuple::make_tuple(
                env,
                &items.iter().map(|i| i.encode(env)).collect::<Vec<_>>(),
            ),
        }
    }
}

impl<'a> Decoder<'a> for Wire {
    fn decode(term: Term<'a>) -> NifResult<Wire> {
        match term.get_type() {
            TermType::Atom => {
                let s: String = rustler::Atom::from_term(term)?
                    .to_term(term.get_env())
                    .atom_to_string()?;
                Ok(if s == "nil" { Wire::Nil } else { Wire::Atom(s) })
            }
            TermType::Integer => Ok(Wire::Int(term.decode()?)),
            TermType::Float => Ok(Wire::Float(term.decode()?)),
            TermType::Binary => Ok(Wire::Bin(term.decode::<Binary>()?.as_slice().to_vec())),
            TermType::List => Ok(Wire::List(
                term.decode::<Vec<Term>>()?
                    .into_iter()
                    .map(Wire::decode)
                    .collect::<NifResult<_>>()?,
            )),
            TermType::Tuple => Ok(Wire::Tuple(
                rustler::types::tuple::get_tuple(term)?
                    .into_iter()
                    .map(Wire::decode)
                    .collect::<NifResult<_>>()?,
            )),
            _ => Err(rustler::Error::BadArg),
        }
    }
}
