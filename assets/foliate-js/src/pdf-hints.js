import { validateEpubEdit, findEpubEditAnchor, textMap } from './epub-edit.js'

const digest = async value => [...new Uint8Array(await crypto.subtle.digest('SHA-256',
    new TextEncoder().encode(value)))].map(x => x.toString(16).padStart(2, '0')).join('')

export function currentReaderContent(view) {
    const contents = view?.renderer?.getContents?.() ?? []
    const range = view?.lastLocation?.range
    return range ? contents.find(x => x.doc === range.startContainer.ownerDocument)
        : contents.find(x => x.index === view?.renderer?.index)
}

export function pdfReaderText(doc, range) {
    const layer = doc?.querySelector('.textLayer')
    if (!layer) return ''
    const map = textMap(layer)
    if (!range) return map.text
    const pieces = []
    for (const { node } of map.nodes) {
        if (!range.intersectsNode(node)) continue
        const from = range.startContainer === node ? range.startOffset : 0
        const to = range.endContainer === node ? range.endOffset : node.length
        pieces.push(node.data.slice(from, to))
    }
    return pieces.join(' ').replace(/\s+/gu, ' ').trim()
}

function anchorRange(doc, anchor, start = anchor.rawStart, end = anchor.rawEnd) {
    const first = anchor.map.nodes.find(x => x.end > start && x.start <= start)
    const last = anchor.map.nodes.find(x => x.end >= end && x.start < end)
    if (!first || !last) throw new Error('The PDF text anchor is unavailable')
    const range = doc.createRange()
    range.setStart(first.node, start - first.start)
    range.setEnd(last.node, end - last.start)
    return range
}

function effectiveAnchor(spec, anchor) {
    if (spec.type !== 'ruby') return anchor
    const words = [...spec.quote.matchAll(/\S+/gu)]
    const word = spec.alignment === 'right' ? words.at(-1) : spec.alignment === 'center' ? words[Math.floor((words.length - 1) / 2)] : words[0]
    return { ...anchor, start: anchor.start + word.index, end: anchor.start + word.index + word[0].length }
}

function sameAnchor(a, b) {
    return a.paragraphHash === b.paragraphHash && a.paragraphIndex === b.paragraphIndex && a.start === b.start && a.end === b.end
}

// Pure preparation: every anchor must resolve before Flutter saves anything.
export async function preparePdfEdits(doc, input, records) {
    if (!doc?.documentElement.hasAttribute('data-anx-pdf-page')) throw new Error('The current page is not a PDF')
    if (!Array.isArray(records) || records.length > 5000) throw new Error('Invalid PDF annotation data')
    const items = input.items ?? [input]
    if (!Array.isArray(items) || !items.length || items.length > 50) throw new Error('Invalid annotation batch')
    const next = records.map(record => ({ ...record })), results = []
    for (const item of items) {
        const spec = validateEpubEdit(item)
        if (spec.type === 'ruby' && spec.mode === 'append') throw new Error('Ruby append is currently supported only in EPUB')
        const requestHash = await digest(JSON.stringify(spec))
        const prior = next.find(x => x.spec.operationId === spec.operationId)
        if (prior) {
            if (prior.requestHash !== requestHash) throw new Error('operationId was already used for another edit')
            results.push({ changed: false, operationId: spec.operationId, anchor: prior.anchor })
            continue
        }
        const anchor = await findEpubEditAnchor(doc, spec)
        if (!anchorRange(doc, anchor).getClientRects().length) throw new Error('PDF phrase has no visible text geometry')
        const stable = { paragraphHash: anchor.paragraphHash, paragraphIndex: anchor.paragraphIndex,
            start: anchor.start, end: anchor.end, quote: spec.quote }
        if (spec.mode === 'overwrite') {
            const target = effectiveAnchor(spec, stable)
            for (const record of next) if (!record.superseded && record.spec.type === spec.type &&
                sameAnchor(effectiveAnchor(record.spec, record.anchor), target)) record.superseded = true
        }
        const record = { spec, requestHash, anchor: stable }
        next.push(record)
        results.push({ changed: true, operationId: spec.operationId, anchor: stable })
    }
    return { records: next, items: results, changed: results.some(x => x.changed), activeCount: next.filter(record => !record.superseded).length }
}

// All geometry stays in the PDF page's local coordinates; the fixed-layout
// renderer scales the page, source text and hints together on resize/rotation.
export async function renderPdfHints(doc, records, showComment) {
    if (!doc?.documentElement.hasAttribute('data-anx-pdf-page')) return
    const root = doc.createElement('div')
    root.setAttribute('data-anx-pdf-hints', '1')
    root.setAttribute('data-anx-edit-added', 'pdf-hints')
    root.style.cssText = 'position:absolute;inset:0;pointer-events:none;z-index:5;overflow:visible'
    let number = 0
    for (const record of records) {
        if (record.superseded) continue
        const spec = validateEpubEdit(record.spec)
        const anchor = await findEpubEditAnchor(doc, { ...spec,
            paragraphHash: record.anchor.paragraphHash, paragraphIndex: record.anchor.paragraphIndex })
        if (anchor.start !== record.anchor.start || anchor.end !== record.anchor.end) throw new Error('Saved PDF anchor changed')
        const range = anchorRange(doc, anchor)
        const rects = [...range.getClientRects()].filter(r => r.width > 0 && r.height > 0)
        const tags = el => {
            el.setAttribute('data-anx-pdf-hint', spec.type)
            el.setAttribute('data-anx-edit-group', spec.group)
            el.setAttribute('data-anx-edit-tier', String(spec.tier))
            if (spec.tags) el.setAttribute('data-anx-hint-tags', JSON.stringify(spec.tags))
        }
        if (spec.type === 'highlight') for (const r of rects) {
            const el = doc.createElement('span')
            tags(el)
            el.style.cssText = `position:absolute;left:${r.left}px;top:${r.top}px;width:${r.width}px;height:${r.height}px;background:${spec.color}66;border-radius:2px`
            if (spec.text) {
                el.style.pointerEvents = 'auto'
                el.setAttribute('role', 'button'); el.tabIndex = 0; el.setAttribute('aria-label', spec.text)
                const open = event => { event.preventDefault(); event.stopPropagation(); showComment(spec.text) }
                el.addEventListener('click', open)
                el.addEventListener('keydown', e => { if (e.key === 'Enter' || e.key === ' ') open(e) })
            }
            root.appendChild(el)
        }
        if (spec.type === 'ruby') {
            const words = [...spec.quote.matchAll(/\S+/gu)]
            const word = spec.alignment === 'right' ? words.at(-1) : spec.alignment === 'center' ? words[Math.floor((words.length - 1) / 2)] : words[0]
            const first = anchor.map.starts[anchor.start + word.index]
            const last = anchor.map.ends[anchor.start + word.index + word[0].length - 1]
            const r = anchorRange(doc, anchor, first, last).getBoundingClientRect()
            const el = doc.createElement('span'); tags(el); el.textContent = spec.text
            const height = Math.max(8, r.height * .45)
            const x = spec.alignment === 'right' ? r.right : spec.alignment === 'center' ? (r.left + r.right) / 2 : r.left
            const translate = spec.alignment === 'right' ? '-100%' : spec.alignment === 'center' ? '-50%' : '0'
            el.style.cssText = `position:absolute;left:${Math.max(0,x)}px;top:${Math.max(0,r.top-height)}px;transform:translateX(${translate});font:${height}px sans-serif;line-height:1;white-space:nowrap;color:#111;background:#ffffffe6;border-radius:2px;max-width:95%;overflow:hidden;text-overflow:ellipsis`
            root.appendChild(el)
        } else if (spec.type === 'footnote' || spec.type === 'highlight' && spec.text) {
            const r = rects.at(-1)
            if (!r) continue
            const el = doc.createElement('button'); tags(el)
            el.type = 'button'; el.textContent = `[${++number}]`; el.setAttribute('aria-label', `Explanation: ${spec.quote}`)
            el.style.cssText = `position:absolute;left:${r.right}px;top:${Math.max(0,r.top-r.height*.25)}px;font:${Math.max(9,r.height*.55)}px sans-serif;color:#1967d2;background:#ffffffe6;border:0;padding:0 1px;line-height:1;pointer-events:auto;cursor:pointer`
            el.addEventListener('click', e => { e.preventDefault(); e.stopPropagation(); showComment(spec.text) })
            root.appendChild(el)
        }
    }
    doc.querySelector('[data-anx-pdf-hints]')?.remove()
    doc.body.appendChild(root)
}
