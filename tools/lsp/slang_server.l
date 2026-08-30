import server;
import slang;

pub fn main() {
    server.run(server.Ops {
        name: "simplec-v5-lsp",
        token_types: ["namespace", "type", "function", "variable", "property", "keyword", "string", "number", "comment", "operator", "enumMember"],
        diagnostics: slang.diagnostics,
        semantic: slang.semantic,
        symbols: slang.symbols,
        completion: slang.completion,
        definition: slang.definition,
        hover: slang.hover,
        format: slang.format,
    });
}
