# web-research-skills

Agent skills that give coding agents web access: web search, web page reading, and up-to-date library documentation.

| Skill                                                      | What it does                                                                                                                                                                                              | Requires                                        |
| ---------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------- |
| [`firecrawl-web-grab`](skills/firecrawl-web-grab/SKILL.md) | Web search and page reading via the [Firecrawl](https://www.firecrawl.dev) API, including JavaScript-rendered pages, site-restricted and recent-news search, screenshots, links and structured extraction | bash, curl, awk, `FIRECRAWL_API_KEY`            |
| [`context7`](skills/context7/SKILL.md)                     | Current docs, API references and code examples for libraries, frameworks and SDKs via the [Context7](https://context7.com) API                                                                            | bash, curl 7.84+, `CONTEXT7_API_KEY` (optional) |

Both skills are plain bash and curl, with no Python, Node or jq needed. Tested on Linux and Windows (Git Bash).

## Install

```bash
npx skills add Artin0123/web-research-skills
```

Or copy a folder from `skills/` into your agent's skills directory.

## Setup

Set the API keys as environment variables:

```bash
export FIRECRAWL_API_KEY="<your-firecrawl-key>"
export CONTEXT7_API_KEY="<your-context7-key>"   # optional; requests are anonymous without it
```

## License

[MIT](LICENSE)
