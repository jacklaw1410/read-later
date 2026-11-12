//! A small XML well-formedness check.
//!
//! It exists to catch a broken generated XAML file without a dependency. It
//! checks tag balance and quoting. It does not check the WinUI schema.

/// Returns the first problem, or `Ok` when every tag opens and closes in order.
pub fn check(text: &str) -> Result<(), String> {
    let bytes = text.as_bytes();
    let mut stack: Vec<String> = Vec::new();
    let mut index = 0;

    while index < bytes.len() {
        if bytes[index] != b'<' {
            index += 1;
            continue;
        }
        let rest = &text[index..];

        if rest.starts_with("<!--") {
            match rest.find("-->") {
                Some(end) => index += end + 3,
                None => return Err("unterminated comment".into()),
            }
            continue;
        }
        if rest.starts_with("<?") {
            match rest.find("?>") {
                Some(end) => index += end + 2,
                None => return Err("unterminated processing instruction".into()),
            }
            continue;
        }
        if rest.starts_with("<!") {
            match rest.find('>') {
                Some(end) => index += end + 1,
                None => return Err("unterminated declaration".into()),
            }
            continue;
        }

        let mut cursor = index + 1;
        let closing = bytes.get(cursor) == Some(&b'/');
        if closing {
            cursor += 1;
        }
        let name_start = cursor;
        while cursor < bytes.len() && !is_name_end(bytes[cursor]) {
            cursor += 1;
        }
        let name = &text[name_start..cursor];

        // Walk to the closing `>`, ignoring any inside an attribute value.
        let mut quote: Option<u8> = None;
        while cursor < bytes.len() {
            let byte = bytes[cursor];
            match quote {
                Some(open) if byte == open => quote = None,
                Some(_) => {}
                None if byte == b'"' || byte == b'\'' => quote = Some(byte),
                None if byte == b'>' => break,
                None => {}
            }
            cursor += 1;
        }
        if cursor >= bytes.len() {
            return Err(format!("unterminated tag <{name}>"));
        }
        let self_closing = bytes[cursor - 1] == b'/';
        index = cursor + 1;

        if closing {
            match stack.pop() {
                Some(open) if open == name => {}
                Some(open) => return Err(format!("</{name}> closes <{open}>")),
                None => return Err(format!("</{name}> has no opening tag")),
            }
        } else if !self_closing {
            stack.push(name.to_string());
        }
    }

    match stack.pop() {
        Some(open) => Err(format!("<{open}> is never closed")),
        None => Ok(()),
    }
}

fn is_name_end(byte: u8) -> bool {
    byte.is_ascii_whitespace() || byte == b'/' || byte == b'>'
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn balanced_tags_pass() {
        assert!(check("<a><b x=\"1\"/><c>text</c></a>").is_ok());
    }

    #[test]
    fn a_comment_is_skipped() {
        assert!(check("<!-- <a> --><a/>").is_ok());
    }

    #[test]
    fn an_unclosed_tag_fails() {
        let error = check("<a><b></a>").unwrap_err();
        assert!(error.contains("closes"), "{error}");
    }

    #[test]
    fn a_close_without_an_open_fails() {
        let error = check("<a/></b>").unwrap_err();
        assert!(error.contains("no opening"), "{error}");
    }

    #[test]
    fn a_quote_hides_the_tag_end() {
        assert!(check("<a x=\"&gt;\"><b/></a>").is_ok());
    }
}
