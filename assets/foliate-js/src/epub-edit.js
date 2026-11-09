import { normalizeHintTags } from './reader-hints.js'
const XHTML = 'http://www.w3.org/1999/xhtml'
const EPUB = 'http://www.idpf.org/2007/ops'
const marker = 'data-anx-edit-added'
const excluded = 'script, style, rt, rp, aside, [role="doc-footnote"], .rl-ref, .rl-ui, [data-anx-ai-ref], [data-anx-edit-added]'
const normalize = value => value.replace(/\s+/gu, ' ').trim()
function ignored(element) {
    if (element.closest(excluded) || element.closest('[role="doc-noteref"]')) return true
    for (let node = element; node; node = node.parentElement) {
        if ((node.getAttributeNS(EPUB, 'type') ?? node.getAttribute('epub:type') ?? '').split(/\s+/u).includes('noteref')) return true
    }
    return false
}
const hash = async value => [...new Uint8Array(await crypto.subtle.digest('SHA-256',
    new TextEncoder().encode(value)))].map(x => x.toString(16).padStart(2, '0')).join('')

function requireText(value, name, max, allowEmpty = false) {
    if (typeof value !== 'string' || value.length > max || (!allowEmpty && !value.trim()))
        throw new Error(`Invalid ${name}`)
    return value
}

export function validateEpubEdit(input) {
    if (!input || typeof input !== 'object') throw new Error('Missing edit input')
    const type = input.type
    if (!['footnote', 'ruby', 'highlight'].includes(type)) throw new Error('Unknown edit type')
    const operationId = requireText(input.operationId, 'operationId', 80)
    if (!/^[A-Za-z0-9._-]+$/.test(operationId)) throw new Error('Invalid operationId')
    const quote = normalize(requireText(input.quote, 'quote', 500))
    const contextBefore = normalize(requireText(input.contextBefore ?? '', 'contextBefore', 300, true))
    const contextAfter = normalize(requireText(input.contextAfter ?? '', 'contextAfter', 300, true))
    if (!contextBefore && !contextAfter && !input.paragraphHash)
        throw new Error('An exact quote needs surrounding context or a verified paragraph hash')
    const text = requireText(input.text ?? (type === 'highlight' ? '' : null), 'text', type === 'ruby' ? 32 : 1200, type === 'highlight').trim()
    const color = input.color ?? '#ffe082'
    if (type === 'highlight' && !/^#[a-f0-9]{6}$/i.test(color)) throw new Error('Invalid highlight color')
    const group = requireText(input.group ?? 'Spanish tutor', 'group', 64)
    const tags = normalizeHintTags(input.tags)
    const tier = input.tier ?? 3
    if (![1, 2, 3].includes(tier)) throw new Error('tier must be 1, 2 or 3')
    const alignment = input.alignment ?? 'left'
    if (!['left', 'center', 'right'].includes(alignment)) throw new Error('Invalid alignment')
    if (input.mode != null && (type !== 'ruby' || !['append', 'overwrite'].includes(input.mode)))
        throw new Error('Invalid ruby mode')
    const occurrence = input.occurrence
    if (occurrence != null && (!Number.isInteger(occurrence) || occurrence < 1))
        throw new Error('Invalid occurrence')
    const paragraphHash = input.paragraphHash ?? null
    if (paragraphHash != null && !/^[a-f0-9]{64}$/.test(paragraphHash))
        throw new Error('Invalid paragraph hash')
    const paragraphIndex = input.paragraphIndex ?? null
    if (paragraphIndex != null && (!Number.isInteger(paragraphIndex) || paragraphIndex < 0))
        throw new Error('Invalid paragraph index')
    return { type, operationId, quote, contextBefore, contextAfter, text, group, tier,
        alignment, occurrence: occurrence ?? null, paragraphHash, paragraphIndex,
        ...(input.mode != null ? { mode: input.mode } : {}),
        ...(Object.keys(tags).length ? { tags } : {}), ...(type === 'highlight' ? { color: color.toLowerCase() } : {}) }
}

export function textMap(block) {
    const pdf = block.classList.contains('textLayer')
    const walker = block.ownerDocument.createTreeWalker(block, 4)
    const nodes = []
    let node, raw = ''
    while ((node = walker.nextNode())) {
        if (ignored(node.parentElement)) continue
        if (pdf && raw && !/\s$/u.test(raw) && !/^\s/u.test(node.data)) raw += ' '
        nodes.push({ node, start: raw.length, end: raw.length + node.data.length })
        raw += node.data
    }
    let text = ''
    const starts = [], ends = []
    for (let i = 0; i < raw.length; i++) {
        if (/\s/u.test(raw[i])) {
            if (!text.length) continue
            if (text.endsWith(' ')) ends[ends.length - 1] = i + 1
            else { text += ' '; starts.push(i); ends.push(i + 1) }
        } else { text += raw[i]; starts.push(i); ends.push(i + 1) }
    }
    if (text.endsWith(' ')) { text = text.slice(0, -1); starts.pop(); ends.pop() }
    return { nodes, text, starts, ends }
}

function blocksOf(doc) {
    if (doc.documentElement.hasAttribute('data-anx-pdf-page')) return [...doc.querySelectorAll('.textLayer')]
    const blocks = [...doc.querySelectorAll('p, li, blockquote, h1, h2, h3, h4, h5, h6, div')]
        .filter(x => !ignored(x) && !x.querySelector('p, li, blockquote, h1, h2, h3, h4, h5, h6, div'))
    return blocks.length ? blocks : [doc.body]
}

export async function findEpubEditAnchor(doc, spec) {
    const candidates = []
    const blocks = blocksOf(doc)
    for (let paragraphIndex = 0; paragraphIndex < blocks.length; paragraphIndex++) {
        if (spec.paragraphIndex != null && spec.paragraphIndex !== paragraphIndex) continue
        const map = textMap(blocks[paragraphIndex])
        const paragraphHash = await hash(map.text)
        if (spec.paragraphHash && paragraphHash !== spec.paragraphHash) continue
        for (let offset = 0; (offset = map.text.indexOf(spec.quote, offset)) !== -1; offset++) {
            const end = offset + spec.quote.length
            if (spec.contextBefore && !map.text.slice(0, offset).trimEnd().endsWith(spec.contextBefore)) continue
            if (spec.contextAfter && !map.text.slice(end).trimStart().startsWith(spec.contextAfter)) continue
            candidates.push({ block: blocks[paragraphIndex], map, paragraphIndex, paragraphHash,
                start: offset, end, rawStart: map.starts[offset], rawEnd: map.ends[end - 1] })
        }
    }
    if (!candidates.length) throw new Error('Exact quote/context anchor was not found; nothing changed')
    if (candidates.length > 1 && spec.occurrence == null)
        throw new Error(`Ambiguous anchor (${candidates.length} matches); supply paragraphHash or explicit occurrence`)
    const index = (spec.occurrence ?? 1) - 1
    if (index >= candidates.length) throw new Error('Requested occurrence does not exist')
    return candidates[index]
}

function added(doc, name, spec) {
    const el = doc.createElementNS(XHTML, name)
    el.setAttribute(marker, spec.type)
    el.setAttribute('data-anx-edit-group', spec.group)
    el.setAttribute('data-anx-edit-tier', String(spec.tier))
    if (spec.tags) el.setAttribute('data-anx-hint-tags', JSON.stringify(spec.tags))
    return el
}

// The gloss lives above one word at the selected edge/centre of the phrase.
// Every original inline element remains in place; no Range.extractContents or
// letter-spacing/table layout can split and stretch the original phrase.
function insertRuby(doc, anchor, spec) {
    const words = [...spec.quote.matchAll(/\S+/gu)]
    const selected = spec.alignment === 'right' ? words[words.length - 1]
        : spec.alignment === 'center' ? words[Math.floor((words.length - 1) / 2)] : words[0]
    const start = anchor.map.starts[anchor.start + selected.index]
    const end = anchor.map.ends[anchor.start + selected.index + selected[0].length - 1]
    const segments = anchor.map.nodes.filter(x => x.end > start && x.start < end)
    if (segments.length !== 1)
        throw new Error('The gloss anchor word crosses inline markup; use a nearby single word')
    const { node, start: nodeStart } = segments[0]
    const existing = node.parentElement.closest('ruby')
    if (existing) {
        // Change only the verified whole base word, never every matching word
        // or a substring of a publisher's longer ruby phrase.
        if (!spec.mode || normalize(textMap(existing).text) !== selected[0])
            throw new Error('The anchor word already has ruby; choose another word or remove the earlier gloss')
        const annotations = [...existing.children].filter(child => child.localName === 'rt')
        if (annotations.length !== 1) throw new Error('Existing ruby has complex annotation markup')
        const rt = annotations[0]
        const replaced = []
        if (spec.mode === 'overwrite') {
            replaced.push(existing.getAttribute('data-anx-edit-id'),
                ...[...rt.querySelectorAll('[data-anx-edit-id]')].map(el => el.getAttribute('data-anx-edit-id')))
            for (const attr of [...rt.attributes]) rt.removeAttributeNode(attr)
            rt.replaceChildren()
            existing.setAttribute('data-anx-edit-id', spec.operationId)
        } else if (!rt.hasAttribute('data-anx-ruby-container')) {
            const old = doc.createElementNS(XHTML, 'span')
            for (const attr of [...rt.attributes]) old.setAttributeNS(attr.namespaceURI, attr.name, attr.value)
            while (rt.firstChild) old.appendChild(rt.firstChild)
            for (const attr of [...rt.attributes]) rt.removeAttributeNode(attr)
            old.setAttribute('data-anx-ruby-gloss', '1')
            if (existing.hasAttribute('data-anx-edit-id')) old.setAttribute('data-anx-edit-id', existing.getAttribute('data-anx-edit-id'))
            rt.appendChild(old)
        }
        rt.setAttribute('data-anx-ruby-container', '1')
        const gloss = added(doc, 'span', spec)
        gloss.setAttribute('data-anx-ruby-gloss', '1')
        gloss.setAttribute('data-anx-edit-id', spec.operationId)
        gloss.textContent = spec.text
        rt.appendChild(gloss)
        return replaced.filter(Boolean)
    }
    const from = start - nodeStart, to = end - nodeStart
    const ruby = doc.createElementNS(XHTML, 'ruby')
    ruby.setAttribute('data-anx-edit-wrap', 'ruby')
    ruby.setAttribute('data-anx-ai-ruby', '1')
    ruby.setAttribute('data-anx-edit-id', spec.operationId)
    ruby.setAttribute('class', `anx-edit-ruby anx-edit-align-${spec.alignment}`)
    ruby.appendChild(doc.createTextNode(node.data.slice(from, to)))
    const rt = added(doc, 'rt', spec)
    rt.textContent = spec.text
    ruby.appendChild(rt)
    node.replaceWith(doc.createTextNode(node.data.slice(0, from)), ruby,
        doc.createTextNode(node.data.slice(to)))
}

function insertFootnote(doc, anchor, spec, number) {
    const segment = anchor.map.nodes.find(x => x.end >= anchor.rawEnd && x.start < anchor.rawEnd)
    if (!segment) throw new Error('Invalid end anchor')
    const offset = anchor.rawEnd - segment.start
    const reference = added(doc, 'a', spec)
    reference.setAttributeNS(EPUB, 'epub:type', 'noteref')
    reference.setAttribute('role', 'doc-noteref')
    reference.setAttribute('id', `anx-ref-${spec.operationId}`)
    reference.setAttribute('href', `#anx-note-${spec.operationId}`)
    reference.setAttribute('class', 'anx-edit-noteref')
    reference.setAttribute('data-anx-ai-ref', '1')
    reference.setAttribute('data-anx-edit-id', spec.operationId)
    reference.textContent = `[${number}]`
    const superscript = added(doc, 'sup', spec)
    superscript.setAttribute('class', 'anx-edit-ref-wrap')
    superscript.appendChild(reference)
    segment.node.replaceWith(doc.createTextNode(segment.node.data.slice(0, offset)), superscript,
        doc.createTextNode(segment.node.data.slice(offset)))
    const note = added(doc, 'aside', spec)
    note.setAttributeNS(EPUB, 'epub:type', 'footnote')
    note.setAttribute('role', 'doc-footnote')
    note.setAttribute('id', `anx-note-${spec.operationId}`)
    note.setAttribute('class', 'anx-edit-footnote')
    note.setAttribute('hidden', 'hidden')
    const paragraph = doc.createElementNS(XHTML, 'p')
    paragraph.textContent = spec.text
    note.appendChild(paragraph)
    doc.body.appendChild(note)
}

function insertHighlight(doc, anchor, spec, number) {
    // Split text nodes only; original inline markup and every source character survive.
    for (const segment of [...anchor.map.nodes].reverse()) {
        const from = Math.max(0, anchor.rawStart - segment.start)
        const to = Math.min(segment.node.length, anchor.rawEnd - segment.start)
        if (from >= to) continue
        const mark = doc.createElementNS(XHTML, 'span')
        mark.setAttribute('data-anx-edit-wrap', 'highlight')
        mark.setAttribute('data-anx-hint-highlight', '1')
        mark.setAttribute('data-anx-edit-group', spec.group)
        mark.setAttribute('data-anx-edit-tier', String(spec.tier))
        if (spec.tags) mark.setAttribute('data-anx-hint-tags', JSON.stringify(spec.tags))
        mark.setAttribute('style', `background-color:${spec.color}66!important;border-radius:.1em;color:inherit`)
        mark.textContent = segment.node.data.slice(from, to)
        segment.node.replaceWith(doc.createTextNode(segment.node.data.slice(0, from)), mark,
            doc.createTextNode(segment.node.data.slice(to)))
    }
    // Rebuild the map after wrapping so an optional comment gets a real popup link.
    if (spec.text) {
        const map = textMap(anchor.block)
        insertFootnote(doc, { ...anchor, map, rawEnd: map.ends[anchor.end - 1] }, spec, number)
    }
}

const styles = `.anx-edit-ref-wrap{font-size:inherit!important;line-height:0!important;vertical-align:baseline!important}.anx-edit-noteref{font-size:.62em!important;line-height:0!important;vertical-align:super!important;white-space:nowrap!important;text-decoration:none!important}.anx-edit-ruby{ruby-position:over!important;ruby-align:center!important;letter-spacing:normal!important;word-spacing:normal!important}.anx-edit-ruby rt{font-size:.48em!important;line-height:1!important;letter-spacing:normal!important;word-spacing:normal!important}.anx-edit-align-left rt{text-align:left!important}.anx-edit-align-right rt{text-align:right!important}[data-anx-edit-added][hidden]{display:none!important}[data-anx-ruby-gloss]:not([hidden]):not([data-anx-hint-filtered])~[data-anx-ruby-gloss]:not([hidden]):not([data-anx-hint-filtered])::before{content:' · '}`

function groupRuntime() {
    const doc = document
    const book = doc.documentElement.getAttribute('data-anx-edit-book')
    if (!book) return
    let host = window
    try { if (parent.document?.body) host = parent } catch (_) { /* local fallback */ }
    const key = `anx-epub-edits:${book}`
    let levels = {}
    try {
        const raw = host.localStorage.getItem(key) || '{}'
        const parsed = raw.length <= 16384 ? JSON.parse(raw) : null
        if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
            levels = Object.fromEntries(Object.entries(parsed).filter(([group, level]) =>
                group.length <= 64 && Number.isInteger(level) && level >= 0 && level <= 3))
        }
    } catch (_) { /* default many */ }
    let unified = !!window.AnxReadingLevels
    const unhideForUnified = () => {
        for (const el of doc.querySelectorAll('[data-anx-ai-ref], .anx-edit-ref-wrap, rt[data-anx-edit-tier]')) el.hidden = false
    }
    if (unified) { unhideForUnified(); return }
    const apply = () => {
        if (unified) return
        for (const el of doc.querySelectorAll('[data-anx-edit-added][data-anx-edit-group]')) {
            if (el.tagName.toLowerCase() === 'aside') continue
            const level = levels[el.getAttribute('data-anx-edit-group')] ?? 3
            el.hidden = Number(el.getAttribute('data-anx-edit-tier')) > level
        }
    }
    apply()
    const groups = [...new Set([...doc.querySelectorAll('[data-anx-edit-group]')]
        .map(x => x.getAttribute('data-anx-edit-group')))]
    if (!groups.length) return
    const managerKey = `__anxEditGroups_${book}`
    let manager = host[managerKey]
    if (!manager) {
        const container = host.document.createElement('div')
        container.setAttribute('data-anx-edit-added', 'controls')
        container.style.cssText = 'position:fixed;right:8px;bottom:48px;z-index:2147483000;font:14px sans-serif;color:#111;background:#fff;border:1px solid #999;border-radius:8px;padding:5px;max-width:90vw;box-shadow:0 2px 10px #0004'
        const button = host.document.createElement('button')
        button.type = 'button'
        button.textContent = 'Подсказки'
        button.setAttribute('aria-label', 'Уровни добавленных подсказок')
        const panel = host.document.createElement('div')
        panel.hidden = true
        button.onclick = () => { panel.hidden = !panel.hidden }
        container.append(button, panel)
        for (const type of ['pointerdown', 'pointerup', 'touchstart', 'touchend', 'click'])
            container.addEventListener(type, event => event.stopPropagation())
        container.addEventListener('keydown', event => {
            if (event.key === 'Escape') { panel.hidden = true; event.stopPropagation(); button.focus() }
        })
        host.document.body.appendChild(container)
        manager = { container, panel, docs: new Map(), groups: new Map() }
        host[managerKey] = manager
    }
    manager.docs.set(doc, () => { levels = manager.levels; apply() })
    manager.levels = { ...levels, ...manager.levels }
    for (const group of groups) {
        if (manager.groups.has(group)) continue
        const row = host.document.createElement('label')
        row.style.cssText = 'display:flex;gap:6px;align-items:center;margin:6px'
        const title = host.document.createElement('span')
        title.textContent = group
        const select = host.document.createElement('select')
        select.setAttribute('aria-label', `Подсказки: ${group}`)
        for (const [i, label] of ['Выкл', 'Редко', 'Средне', 'Много'].entries()) {
            const option = host.document.createElement('option')
            option.value = String(i); option.textContent = label; select.appendChild(option)
        }
        select.value = String(manager.levels[group] ?? 3)
        select.onchange = () => {
            manager.levels[group] = Number(select.value)
            try { host.localStorage.setItem(key, JSON.stringify(manager.levels)) } catch (_) { /* session only */ }
            for (const update of manager.docs.values()) update()
        }
        row.append(title, select); manager.panel.appendChild(row); manager.groups.set(group, row)
    }
    const cleanup = () => {
        manager.docs.delete(doc)
        if (!manager.docs.size) { manager.container.remove(); delete host[managerKey] }
    }
    const adoptUnified = event => {
        if (unified) return
        const expected = window.AnxReadingLevels?.get?.().bookId ?? window.READING_LIVE?.bookId
        if (!expected || event.detail?.bookId !== expected) return
        unified = true
        unhideForUnified()
        cleanup()
        window.removeEventListener('anx-reading-levels', adoptUnified)
    }
    window.addEventListener('anx-reading-levels', adoptUnified)
    window.addEventListener('pagehide', () => {
        window.removeEventListener('anx-reading-levels', adoptUnified)
        cleanup()
    }, { once: true })
}

async function prepareSingleEpubEdit(source, input, bookKey) {
    const spec = validateEpubEdit(input)
    const doc = new DOMParser().parseFromString(source, 'application/xhtml+xml')
    if (doc.querySelector('parsererror') || !doc.body || !doc.head) throw new Error('Invalid XHTML chapter')
    let metadata = doc.querySelector('script[data-anx-edit-metadata]')
    if (metadata && metadata.textContent.length > 1024 * 1024)
        throw new Error('Existing edit metadata is too large')
    const records = metadata ? JSON.parse(metadata.textContent) : []
    if (!Array.isArray(records) || records.length > 5000 || records.some(record =>
        !record || typeof record !== 'object' ||
        !/^[A-Za-z0-9._-]{1,80}$/.test(record.operationId) ||
        !['footnote', 'ruby', 'highlight'].includes(record.type) || !/^[a-f0-9]{64}$/.test(record.requestHash) ||
        !/^[a-f0-9]{64}$/.test(record.semanticHash) ||
        typeof record.group !== 'string' || record.group.length > 64 || ![1, 2, 3].includes(record.tier) ||
        !record.anchor || !/^[a-f0-9]{64}$/.test(record.anchor.paragraphHash) ||
        !Number.isInteger(record.anchor.paragraphIndex) || record.anchor.paragraphIndex < 0 ||
        !Number.isInteger(record.anchor.start) || record.anchor.start < 0 ||
        !Number.isInteger(record.anchor.end) || record.anchor.end <= record.anchor.start ||
        typeof record.anchor.quote !== 'string' || record.anchor.quote.length > 500))
        throw new Error('Invalid existing edit metadata')
    const requestHash = await hash(JSON.stringify(spec))
    const prior = records.find(x => x.operationId === spec.operationId)
    if (prior) {
        if (prior.requestHash !== requestHash) throw new Error('operationId was already used for another edit')
        return { unchanged: true, anchor: prior.anchor, operationId: spec.operationId }
    }
    const anchor = await findEpubEditAnchor(doc, spec)
    const stableAnchor = { paragraphHash: anchor.paragraphHash, paragraphIndex: anchor.paragraphIndex,
        start: anchor.start, end: anchor.end, quote: spec.quote }
    const semanticHash = await hash(JSON.stringify({ type: spec.type, anchor: stableAnchor,
        text: normalize(spec.text), group: spec.group, tier: spec.tier,
        alignment: spec.type === 'ruby' ? spec.alignment : null, ...(spec.mode ? { mode: spec.mode } : {}), ...(spec.tags ? { tags: spec.tags } : {}), ...(spec.type === 'highlight' ? { color: spec.color } : {}) }))
    const sameEdit = records.find(x => !x.superseded && x.semanticHash === semanticHash)
    if (sameEdit) return { unchanged: true, anchor: sameEdit.anchor, operationId: sameEdit.operationId }
    if (spec.type === 'ruby') {
        const replaced = insertRuby(doc, anchor, spec) ?? []
        for (const record of records) if (replaced.includes(record.operationId)) record.superseded = true
    }
    else if (spec.type === 'highlight') insertHighlight(doc, anchor, spec, records.filter(x => x.type === 'footnote' || x.type === 'highlight' && x.text).length + 1)
    else insertFootnote(doc, anchor, spec, records.filter(x => x.type === 'footnote' || x.type === 'highlight' && x.text).length + 1)
    records.push({ operationId: spec.operationId, type: spec.type, requestHash, semanticHash,
        group: spec.group, tier: spec.tier, ...(spec.type === 'highlight' ? { text: spec.text } : {}), ...(spec.tags ? { tags: spec.tags } : {}), anchor: stableAnchor })
    if (!metadata) {
        metadata = doc.createElementNS(XHTML, 'script')
        metadata.setAttribute('type', 'application/json')
        metadata.setAttribute('data-anx-edit-metadata', '1')
        doc.head.appendChild(metadata)
    }
    metadata.textContent = JSON.stringify(records)
    if (!doc.querySelector('style[data-anx-edit-style]')) {
        const style = doc.createElementNS(XHTML, 'style')
        style.setAttribute('data-anx-edit-style', '1'); style.textContent = styles; doc.head.appendChild(style)
    }
    // Existing books carry the earlier editor CSS: refresh it as well, so
    // newly appended glosses get their separator after an app upgrade.
    doc.querySelector('style[data-anx-edit-style]').textContent = styles
    if (!doc.querySelector('script[data-anx-edit-runtime]')) {
        const script = doc.createElementNS(XHTML, 'script')
        script.setAttribute('data-anx-edit-runtime', '1')
        script.textContent = `if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',${groupRuntime.toString()},{once:true});else (${groupRuntime.toString()})()`
        doc.head.appendChild(script)
    }
    doc.documentElement.setAttribute('data-anx-edit-book', bookKey)
    const xhtml = new XMLSerializer().serializeToString(doc)
    if (new DOMParser().parseFromString(xhtml, 'application/xhtml+xml').querySelector('parsererror'))
        throw new Error('Generated chapter failed XHTML validation')
    return { xhtml, unchanged: false, anchor: stableAnchor, operationId: spec.operationId }
}

// All intermediate documents remain inert strings. The bridge receives XHTML
// only when EVERY item succeeds, so invalid/ambiguous/overlapping batches cannot
// partially mutate the EPUB. Anchors always map original text (rt/notes excluded).
export async function prepareEpubEdit(source, input, bookKey) {
    if (!input || !Object.hasOwn(input, 'items')) return prepareSingleEpubEdit(source, input, bookKey)
    if (Object.keys(input).some(key => key !== 'items') || !Array.isArray(input.items)
        || input.items.length < 1 || input.items.length > 50
        || new TextEncoder().encode(JSON.stringify(input)).length > 128 * 1024)
        throw new Error('Invalid batch input')
    for (const item of input.items) validateEpubEdit(item)
    let xhtml = source
    const items = []
    for (const item of input.items) {
        const result = await prepareSingleEpubEdit(xhtml, item, bookKey)
        items.push({ changed: !result.unchanged, operationId: result.operationId, anchor: result.anchor })
        if (!result.unchanged) xhtml = result.xhtml
    }
    const unchanged = items.every(item => !item.changed)
    return { unchanged, items, ...(!unchanged ? { xhtml } : {}) }
}

export async function prepareEpubEditForBridge(source, input, bookKey) {
    try { return await prepareEpubEdit(source, input, bookKey) }
    catch (error) {
        const message = String(error?.message ?? '')
        const code = /^Ambiguous anchor \(\d+ matches\)/.test(message) ? 'ambiguous'
            : message.startsWith('Exact quote/context anchor was not found') ? 'not_found'
            : message.startsWith('The anchor word already has ruby') ? 'ruby_overlap'
            : message.startsWith('The gloss anchor word crosses inline markup') ? 'word_markup'
            : message.startsWith('operationId was already used') ? 'operation_collision'
            : message.startsWith('An exact quote needs surrounding context') ? 'missing_context'
            : message.startsWith('Requested occurrence does not exist') ? 'occurrence_missing'
            : message.includes('edit metadata') ? 'invalid_metadata'
            : message.includes('XHTML') ? 'invalid_xhtml' : 'invalid_input'
        return { editError: code }
    }
}

export async function captureReaderEditLocation(view) {
    const range = view?.lastLocation?.range
    const contents = view?.renderer?.getContents?.() ?? []
    const content = range ? contents.find(x => x.doc === range.startContainer.ownerDocument) : contents.find(x => x.index === view?.renderer?.index)
    const doc = content?.doc
    if (doc?.documentElement.hasAttribute('data-anx-pdf-page')) {
        const text = textMap(doc.querySelector('.textLayer')).text
        return { index: content.index, chapterHref: view.book.sections[content.index].id, paragraphHash: await hash(text), paragraphIndex: 0 }
    }
    const chapterHref = view?.book?.sections?.[content?.index]?.id ?? view?.lastLocation?.tocItem?.href ?? ''
    if (!range || !content) throw new Error('Reader location is not ready')
    const element = range.startContainer.nodeType === 1 ? range.startContainer : range.startContainer.parentElement
    const blocks = blocksOf(doc)
    let block = blocks.find(x => (x === element || x.contains(range.startContainer)) && textMap(x).nodes.length)
    if (!block) {
        const textBlocks = blocks.filter(x => textMap(x).nodes.length)
        block = textBlocks.filter(x => { try { return range.comparePoint(x, 0) <= 0 } catch (_) { return false } }).at(-1) ?? textBlocks[0]
    }
    if (!block) {
        const images = [...doc.querySelectorAll('img')]
        const index = images.findIndex(image => { try { return range.intersectsNode(image) } catch (_) { return false } })
        if (index < 0) throw new Error('Cannot preserve current reader position')
        const imageRange = doc.createRange(); imageRange.selectNode(images[index]); imageRange.collapse(true)
        return { index: content.index, baseCfi: view.getCFI(content.index, imageRange), chapterHref, imageIndex: index }
    }
    const map = textMap(block)
    let rawOffset = 0
    const caret = range.cloneRange(); caret.collapse(true)
    for (const entry of map.nodes) {
        if (entry.node === range.startContainer) { rawOffset += range.startOffset; break }
        if (caret.comparePoint(entry.node, 0) >= 0) break
        rawOffset += entry.node.data.length
    }
    const next = map.ends.findIndex(end => end > rawOffset)
    const offset = next < 0 ? map.text.length : next
    // A spine-only CFI cannot be resolved as a document position. Boot the
    // reloaded chapter at a valid local body range, then restore the exact text.
    const chapterStart = doc.createRange()
    chapterStart.selectNodeContents(doc.body); chapterStart.collapse(true)
    return { index: content.index, baseCfi: view.getCFI(content.index, chapterStart), chapterHref,
        paragraphHash: await hash(map.text), paragraphIndex: blocks.indexOf(block), offset }
}

export async function restoreReaderEditLocation(viewOrGetter, location) {
    if (Number.isInteger(location?.index) && Number.isInteger(location.imageIndex) && location.imageIndex >= 0 && location.imageIndex < 5000) {
        for (let attempt = 0; attempt < 100; attempt++) {
            const view = typeof viewOrGetter === 'function' ? viewOrGetter() : viewOrGetter
            const doc = view?.renderer?.getContents?.().find(x => x.index === location.index)?.doc
            const image = doc?.querySelectorAll('img')[location.imageIndex]
            if (image) {
                const range = doc.createRange(); range.selectNode(image); range.collapse(true)
                await view.renderer.goTo({ index: location.index, anchor: () => range })
                return { restored: true, cfi: view.getCFI(location.index, range) }
            }
            await new Promise(resolve => setTimeout(resolve, 50))
        }
        throw new Error('Saved image position was not found after reloading')
    }
    if (!Number.isInteger(location?.index) || !/^[a-f0-9]{64}$/.test(location?.paragraphHash) ||
        !Number.isInteger(location.offset) || location.offset < 0) throw new Error('Invalid saved reader location')
    for (let attempt = 0; attempt < 100; attempt++) {
        const view = typeof viewOrGetter === 'function' ? viewOrGetter() : viewOrGetter
        const content = view?.renderer?.getContents?.().find(x => x.index === location.index)
        if (content?.doc?.body) {
            const blocks = blocksOf(content.doc)
            const preferred = blocks[location.paragraphIndex]
            let matches = []
            if (preferred && await hash(textMap(preferred).text) === location.paragraphHash) matches = [preferred]
            else for (const block of blocks) {
                if (await hash(textMap(block).text) === location.paragraphHash) matches.push(block)
            }
            if (matches.length > 1) throw new Error('Saved reading paragraph is ambiguous; position was not changed')
            for (const block of matches) {
                const map = textMap(block)
                const offset = Math.min(location.offset, map.text.length)
                const raw = map.starts[offset] ?? map.ends.at(-1) ?? 0
                const entry = map.nodes.find(x => x.start <= raw && x.end >= raw)
                if (!entry) throw new Error('Saved paragraph is empty')
                const range = content.doc.createRange()
                range.setStart(entry.node, raw - entry.start); range.collapse(true)
                await view.renderer.goTo({ index: location.index, anchor: () => range })
                return { restored: true, cfi: view.getCFI(location.index, range) }
            }
        }
        await new Promise(resolve => setTimeout(resolve, 50))
    }
    throw new Error('The saved reading paragraph was not found after reloading')
}
