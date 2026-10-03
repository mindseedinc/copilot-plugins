# Research workflows

Playbooks for turning SocialCrawl results into findings. Commands assume
`S="<skill-directory>/scripts/socialcrawl.py"`. Confirm any endpoint with
`python3 "$S" endpoint <id>` before its first use.

## Query design

- Write queries the way people post: `"Rivian R2 range real world"`, not
  `"Rivian R2 electric vehicle range specifications"`.
- Add intent words to surface opinions: `review`, `experience`, `worth it`,
  `problems`, `regret`, `vs`.
- Keep queries under ~80 characters. If results are sparse, broaden
  (`"Rivian R2"`); if they are noisy, add a disambiguating word or use
  `relevance=filter` on endpoints that support it.
- Run positive and negative angles separately so both sides are represented.

## Sentiment and review research

Pass A - landscape (pick one):

```sh
python3 "$S" search forums "<product> review" --output "${TMPDIR:-/tmp}/socialcrawl/forums.json"
python3 "$S" search everywhere "<product>"        # 20 credits; ask first if budget matters
python3 "$S" search multi "<product> review" platforms=reddit,youtube,tiktok
```

Pass B - drill down:

```sh
python3 "$S" search forums "<product> problems issues"
python3 "$S" search forums "<product> worth it"
```

Pass C - comparisons: `python3 "$S" search forums "<product> vs <competitor>"`.

Pass D - structured reviews (stores, apps, local businesses):

```sh
python3 "$S" endpoints --search "reviews"            # Amazon, Trustpilot, G2, app stores, Yelp, ...
python3 "$S" endpoint <platform>/<reviews-endpoint>
```

Pass E - depth on the best threads or videos: fetch comments or transcripts for the
two or three most relevant items (`endpoints --search "comments"` or `"transcript"`).

## Reading results

Social rows are usually `data.items[].post` with `content.text`, `author.username`,
`engagement` (`likes`, `comments`, `shares`, `views`), `published_at`, and a URL
field. Composite searches add `computed` judgments such as stance and relevance.
Fields a platform does not provide are `null`; do not fill them in.

Engagement means different things per platform:

| Platform | Strong signal |
| --- | --- |
| Reddit | High comment count: detailed advice or debate, often more useful than raw upvotes |
| YouTube | Views plus comments; established reviewer channels over reposts |
| TikTok / Instagram | Shares and comments; views are inflated by recommendation feeds |
| Forums (HN, Quora) | Thread depth and answer quality |

Useful local analysis (after `--output`):

```sh
python3 -c 'import json,sys
for i in json.load(open(sys.argv[1]))["data"]["items"]:
    p = i.get("post") or i
    print((p.get("engagement") or {}).get("comments"), "|", ((p.get("content") or {}).get("text") or "")[:100])' result.json
```

## What to extract

1. Recurring praise themes, with how many independent sources mention each.
2. Recurring complaints and whether they are resolved in newer versions.
3. Price sentiment: prices paid, deals, overpay warnings.
4. Competitors mentioned and which way comparisons lean.
5. Recency: the date range covered, and whether sentiment shifted over time.

## Report template

```markdown
## Public sentiment: <topic>

Sources: N results from <platforms>, <earliest>-<latest>. Credits used: X.

### What people like
- Theme (N sources) - [example](url)

### What people criticize
- Issue (N sources) - [example](url)

### Comparisons
- Most compared with: ...

### Notable sources
- [Title](url) - why it matters

Limitations: sample of public posts returned by search; not exhaustive or
statistically representative.
```

## Before presenting

- Findings cite at least two independent sources where possible.
- Results span several authors or communities, not one thread or channel.
- Dates are recent enough for the question.
- Spot-check that cited URLs are the ones returned by the API.
- State credits used and any platforms that failed or returned nothing.
