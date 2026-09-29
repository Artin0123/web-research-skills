---
name: context7
description: "Look up current docs, API references, and code examples for libraries, frameworks, SDKs, CLI tools, and cloud services (e.g. React, Next.js, Wrangler) via the Context7 API. Use when unsure, likely outdated, or facing a library-specific error. Prefer this over web search tools for library documentation and API details."
compatibility: "Requires bash and curl 7.84+. CONTEXT7_API_KEY is optional."
---

# Context7 Documentation Lookup

Two steps: resolve a library name to a library ID, then query that library's docs.

## Authentication

Commands send `Authorization: Bearer $CONTEXT7_API_KEY`. If the variable is unset, the request is anonymous. Never print the variable or write the key directly into a command.

## Step 1: Resolve a library ID

Skip this step if you already have an ID in the form `/org/project` or `/org/project/version`.

```bash
curl -sSG "https://context7.com/api/v2/libs/search" \
  -H "Authorization: Bearer $CONTEXT7_API_KEY" \
  --data-urlencode "libraryName=Next.js" \
  --data-urlencode "query=How to add middleware to app router" \
  -w "\nHTTP %{http_code} | quota %header{ratelimit-remaining}/%header{ratelimit-limit}\n"
```

- `libraryName`: the official name with its punctuation (`Next.js`, not `nextjs`). If results look wrong, try an alternate spelling before changing the query.
- `query`: the intent behind the question. It affects ranking and disambiguates similarly named libraries.

Pick the result whose `title` and `description` best match the intent, then weigh `totalSnippets`, `trustScore` (0 to 10), and `benchmarkScore` (0 to 100); higher is better for all three. Prefer official sources over forks and mirrors. If the choice is genuinely ambiguous, ask for clarification. For a specific version, append the closest tag from `versions`: `/org/project/<tag>`.

## Step 2: Query documentation

```bash
curl -sSG "https://context7.com/api/v2/context?libraryId=/vercel/next.js" \
  -H "Authorization: Bearer $CONTEXT7_API_KEY" \
  --data-urlencode "query=How to add middleware to app router" \
  -w "\nHTTP %{http_code} | quota %header{ratelimit-remaining}/%header{ratelimit-limit}\n"
```

Keep `libraryId` in the URL rather than a separate argument, since some shells rewrite arguments with a leading `/` into local paths. Cite `Source:` URLs when they support the answer.

### Writing good queries

Keep each query to one specific topic; split multi-concept questions into separate queries unless they are about how the concepts interact. Describe what to look up in the docs, not the task to complete: `React useEffect cleanup with async operations`, not `hooks`.

Never include API keys, passwords, credentials, personal data, or proprietary code in `libraryName` or `query`.

Per question, call each step (Step 1 and Step 2) at most 3 times. Retries described in "Quota and errors" don't count. If that isn't enough, use the best result you have.

## Quota and errors

The last output line is `HTTP <code> | quota <remaining>/<limit>`, so never spend a separate request checking quota. Keyed and anonymous requests draw on separate monthly quotas. If `remaining` drops below 20, report it once.

For other errors, follow the response's `message`.

- **HTTP 401 or 429 with the key**: report it, then rerun once without the `-H` line (anonymous).
- **429 again when anonymous**: report that Context7 quota is exhausted (it resets monthly), then answer from training knowledge and state that it may be outdated.

Never silently fall back to training knowledge; always report why Context7 wasn't used.
