import { findEpubEditAnchor } from './epub-edit.js'
const XHTML = 'http://www.w3.org/1999/xhtml'

export async function prepareBookImageInsertion(source, spec) {
    const doc = new DOMParser().parseFromString(source, 'application/xhtml+xml')
    if (doc.querySelector('parsererror') || !doc.body) throw new Error('Invalid XHTML chapter')
    if (!/^[A-Za-z0-9._-]{1,80}$/.test(spec.operationId) || !/^[a-f0-9]{64}$/.test(spec.requestHash)) throw new Error('Invalid image operation')
    for (const element of doc.querySelectorAll('[data-anx-image-operation-id]')) {
        if (element.getAttribute('data-anx-image-operation-id') !== spec.operationId) continue
        if (element.getAttribute('data-anx-image-request-hash') !== spec.requestHash) throw new Error('Image operationId was already used with different arguments')
        return { unchanged: true, operationId: spec.operationId }
    }
    const anchor = await findEpubEditAnchor(doc, spec)
    if (typeof spec.imageHref !== 'string' || !/^(?:\.\.\/)*[A-Za-z0-9_%./-]+\.png$/.test(spec.imageHref)) throw new Error('Invalid embedded image resource')
    const figure = doc.createElementNS(XHTML, 'figure')
    figure.setAttribute('data-anx-edit-added', 'illustration')
    figure.setAttribute('data-anx-image-operation-id', spec.operationId)
    figure.setAttribute('data-anx-image-request-hash', spec.requestHash)
    figure.setAttribute('style', 'margin:1em 0;max-width:100%;text-indent:0')
    const image = doc.createElementNS(XHTML, 'img')
    image.setAttribute('src', spec.imageHref)
    image.setAttribute('alt', String(spec.caption ?? '').slice(0, 400))
    image.setAttribute('style', 'display:block;max-width:100%;height:auto;margin:0 auto')
    figure.appendChild(image)
    if (spec.caption) {
        const caption = doc.createElementNS(XHTML, 'figcaption')
        caption.textContent = String(spec.caption).slice(0, 400)
        caption.setAttribute('style', 'font-size:.8em;text-align:center;text-indent:0')
        figure.appendChild(caption)
    }
    if (['li', 'blockquote', 'body'].includes(anchor.block.tagName.toLowerCase())) anchor.block.appendChild(figure)
    else anchor.block.after(figure)
    return { xhtml: new XMLSerializer().serializeToString(doc), unchanged: false,
        anchor: { paragraphHash: anchor.paragraphHash, paragraphIndex: anchor.paragraphIndex }, operationId: spec.operationId }
}

export function darkBookBackground(color, doc = document) {
    try {
        const canvas = doc.createElement('canvas'); canvas.width = canvas.height = 1
        const context = canvas.getContext('2d'); context.fillStyle = color; context.fillRect(0, 0, 1, 1)
        const [r, g, b, a] = context.getImageData(0, 0, 1, 1).data
        return a ? .2126 * r + .7152 * g + .0722 * b < 128 : !!doc.defaultView.matchMedia?.('(prefers-color-scheme:dark)').matches
    } catch (_) { return false }
}

export function applyBookImageTheme(doc, dark) {
    for (const image of doc.querySelectorAll('img[data-anx-image-original-src]')) {
        const source = dark && image.getAttribute('data-anx-image-dark-src') ||
            image.getAttribute('data-anx-image-base-src') || image.getAttribute('data-anx-image-original-src')
        if (source && image.getAttribute('src') !== source) image.setAttribute('src', source)
    }
}

export function visibleBookImageIndices(view) {
    const range = view?.lastLocation?.range
    const doc = range?.startContainer?.ownerDocument
    if (!doc) return []
    return [...doc.querySelectorAll('img')].flatMap((image, index) => {
        try { return range.intersectsNode(image) ? [index] : [] } catch (_) { return [] }
    })
}
