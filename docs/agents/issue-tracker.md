# Issue tracker: GitHub

Issues and PRDs for this repo live as GitHub issues in `gsmlg-opt/Synapsis`. Use the `gh` CLI for all operations.

## Conventions

- Create: `gh issue create --title "..." --body "..."`
- Read: `gh issue view <number> --comments`
- List: `gh issue list --state open --json number,title,body,labels,comments`
- Comment: `gh issue comment <number> --body "..."`
- Label: `gh issue edit <number> --add-label "..."`
- Close: `gh issue close <number> --comment "..."`

When a skill says "publish to the issue tracker", create a GitHub issue.
When a skill says "fetch the relevant ticket", run `gh issue view <number> --comments`.
