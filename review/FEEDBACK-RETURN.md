# Returning feedback

The intended review loop is deliberately non-ceremonial:

1. Reviewer returns a Markdown review/change proposal.
2. The language designer reproduces important claims where possible.
3. Each substantive item is classified as:
   - **accept** — change Core/library/host/tooling;
   - **accept with modification** — problem is valid but proposed solution is not;
   - **defer** — plausible but insufficient evidence/priority;
   - **reject** — conflicts with project goals, belongs in another layer, costs too much for benefit, is based on a false premise, or is otherwise not persuasive.
4. Accepted/rejected items should get explicit reasoning rather than consensus-by-default.
5. Changes are re-tested against implementation simplicity, real-program usability, and independent backends/tooling.

Feedback does not need to agree with the current design. It does need to be concrete enough to evaluate.
