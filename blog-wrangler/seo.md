# SEO Optimization Task

## Project Background

This project is deployed on **Cloudflare Worker**.

Current domain:

```
https://flandretiamat.dpdns.org/
```

Current status:

- HTTPS enabled
- HTTP 200
- HTML returned correctly
- Google indexing allowed
- robots.txt managed by Cloudflare
- No sitemap.xml
- Frontend is a Vue SPA

Current HTML:

```html
<body>
    <div id="app"></div>
</body>
```

Google can execute JavaScript, but this structure is not SEO-friendly because almost no meaningful HTML exists before hydration.

---

# Goal

Improve SEO while **keeping all existing functionality unchanged**.

Do NOT redesign the project.

Do NOT change business logic.

Only improve search engine discoverability, indexing quality and metadata.

---

# Tasks

## 1. Improve HTML metadata

Ensure every page contains:

- title
- meta description
- charset
- viewport
- theme-color (optional)
- language declaration

Example:

```html
<title>FLandre.Sys</title>

<meta
    name="description"
    content="FLandre.Sys - ..."
>
```

The description should describe the project rather than using placeholder text.

---

## 2. Add Open Graph metadata

Add:

```
og:title
og:description
og:type
og:url
og:image (optional)
```

Also add Twitter Card metadata if possible.

---

## 3. Add Canonical URL

Example

```html
<link
    rel="canonical"
    href="https://flandretiamat.dpdns.org/"
>
```

---

## 4. Improve initial HTML

The current page only contains

```html
<div id="app"></div>
```

Improve the initial HTML so search engines can understand the page before JavaScript executes.

Requirements:

- keep SPA architecture
- keep hydration working
- do not break Vue mounting
- add meaningful static HTML
- add semantic tags

Example structure:

```
main

h1

description

section

footer
```

The static content should describe the project.

---

## 5. Semantic HTML

Prefer semantic elements:

```
<header>

<main>

<section>

<article>

<footer>

<nav>
```

Avoid div-only layout where possible.

---

## 6. Generate sitemap.xml

If no sitemap exists, create one.

At minimum include:

```
/
```

Automatically generate if routing supports it.

---

## 7. robots.txt

Keep Google indexing enabled.

Do NOT add:

```
Disallow: /
```

Do NOT add

```
noindex
```

---

## 8. Improve page title

Avoid generic titles.

Current:

```
FLandre.Sys
```

Prefer something descriptive.

Example:

```
FLandre.Sys - AI-powered Browser Activity Analysis
```

Choose wording that best matches the actual project.

---

## 9. Meta Description

Generate a concise description (100~160 characters).

Requirements:

- explain the project
- natural language
- no keyword stuffing

---

## 10. Structured Data

If appropriate, add JSON-LD.

Example type:

```
WebSite
SoftwareApplication
Organization
```

Only if accurate.

---

## 11. Favicon

Keep existing favicon unless a better project icon already exists.

---

## 12. Performance

Without changing architecture:

- preload important assets if beneficial
- reduce unnecessary blocking resources
- preserve existing caching strategy

---

# Constraints

Must NOT:

- rewrite frontend
- migrate framework
- convert SPA into SSR
- change routing behavior
- remove Cloudflare Worker support
- change deployment method

Must:

- preserve all existing functionality
- preserve Vue hydration
- preserve existing APIs

---

# Deliverables

Implement directly in the project.

For every modification:

1. Explain why it improves SEO.
2. Show the modified file.
3. Keep changes minimal.
4. Do not introduce unnecessary dependencies.

---

# Success Criteria

Google should be able to:

- discover the site
- understand the site's purpose
- index meaningful HTML
- obtain metadata
- find sitemap.xml
- understand page hierarchy
- identify canonical URL
- read structured metadata

No existing functionality should regress.