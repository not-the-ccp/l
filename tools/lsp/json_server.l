import server;
import json_server_impl as impl;

pub fn main() {
    server.run(server.Ops {
        name: "simplec-v5-json-lsp",
        token_types: ["namespace", "type", "function", "variable", "property", "keyword", "string", "number", "comment", "operator", "enumMember"],
        diagnostics: impl.diagnostics,
        semantic: impl.semantic,
        symbols: impl.symbols,
        completion: impl.completion,
        definition: impl.definition,
        hover: impl.hover,
        format: impl.format,
    });
}
