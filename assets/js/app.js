// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/spacetraders"
import topbar from "../vendor/topbar"

const SystemMap = {
  mounted() {
    this.svg = this.el
    this.container = this.svg.closest(".system-map-canvas")
    this.viewBox = this.svg.viewBox.baseVal
    this.pointers = new Map()
    this.lastPan = null
    this.dragStart = null
    this.dragged = false
    this.suppressClick = false
    this.initialViewBox = {
      x: this.viewBox.x,
      y: this.viewBox.y,
      width: this.viewBox.width,
      height: this.viewBox.height,
    }
    this.lastPinch = null
    this.viewport = null

    this.onWheel = event => {
      event.preventDefault()
      const point = this.pointAt(event.clientX, event.clientY)
      const factor = event.deltaY < 0 ? 0.85 : 1.18
      this.zoomAt(point, factor)
    }

    this.onPointerDown = event => {
      this.pointers.set(event.pointerId, {x: event.clientX, y: event.clientY})
      this.lastPan = this.pointAt(event.clientX, event.clientY)
      this.lastPinch = this.pinchState()
      this.dragStart = {pointerId: event.pointerId, x: event.clientX, y: event.clientY}
      this.dragged = false
    }

    this.onPointerMove = event => {
      if (!this.pointers.has(event.pointerId)) return

      this.pointers.set(event.pointerId, {x: event.clientX, y: event.clientY})
      const points = [...this.pointers.values()]

      if (points.length === 1 && this.lastPan) {
        if (!this.dragged && this.dragStart && Math.hypot(
          event.clientX - this.dragStart.x,
          event.clientY - this.dragStart.y,
        ) < 8) return

        this.dragged = true
        this.suppressClick = true
        this.svg.setPointerCapture(event.pointerId)
        event.preventDefault()
        const point = this.pointAt(event.clientX, event.clientY)
        this.viewBox.x -= point.x - this.lastPan.x
        this.viewBox.y -= point.y - this.lastPan.y
        this.lastPan = this.pointAt(event.clientX, event.clientY)
        this.positionInspector()
      } else if (points.length === 2) {
        this.dragged = true
        this.suppressClick = true
        if (!this.svg.hasPointerCapture(event.pointerId)) this.svg.setPointerCapture(event.pointerId)
        event.preventDefault()
        const pinch = this.pinchState()

        if (this.lastPinch) {
          this.zoomAt(pinch.center, this.lastPinch.distance / Math.max(pinch.distance, 1))
        }

        this.lastPinch = this.pinchState()
      }
    }

    // Safari can still page-zoom inside an SVG despite touch-action: none.
    this.onTouchMove = event => event.preventDefault()
    this.onGesture = event => event.preventDefault()

    this.onPointerUp = event => {
      this.pointers.delete(event.pointerId)
      if (this.svg.hasPointerCapture(event.pointerId)) this.svg.releasePointerCapture(event.pointerId)
      const [pointer] = this.pointers.values()
      this.lastPan = pointer ? this.pointAt(pointer.x, pointer.y) : null
      this.lastPinch = this.pinchState()

      if (!pointer && this.dragged) {
        window.setTimeout(() => this.suppressClick = false, 0)
      }
    }

    this.onClick = event => {
      if (!this.suppressClick) return
      event.preventDefault()
      event.stopImmediatePropagation()
    }

    this.onControlClick = event => {
      const control = event.target.closest("[data-map-control]")
      if (!control) return

      event.preventDefault()
      const center = {
        x: this.viewBox.x + this.viewBox.width / 2,
        y: this.viewBox.y + this.viewBox.height / 2,
      }

      if (control.dataset.mapControl === "zoom-in") this.zoomAt(center, 0.85)
      if (control.dataset.mapControl === "zoom-out") this.zoomAt(center, 1.18)
      if (control.dataset.mapControl === "reset") this.resetView()
    }

    this.onResize = () => {
      this.resizeMarkers()
      this.positionInspector()
    }

    this.onKeyDown = event => {
      if (event.target.classList.contains("system-map-waypoint") && ["Enter", " "].includes(event.key)) {
        event.preventDefault()
        event.target.dispatchEvent(new MouseEvent("click", {bubbles: true}))
        return
      }

      if (event.target !== this.svg) return

      const center = {
        x: this.viewBox.x + this.viewBox.width / 2,
        y: this.viewBox.y + this.viewBox.height / 2,
      }
      const pan = {ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1]}[event.key]

      if (pan) {
        event.preventDefault()
        this.viewBox.x += pan[0] * this.viewBox.width / 10
        this.viewBox.y += pan[1] * this.viewBox.height / 10
        this.positionInspector()
      } else if (["+", "="].includes(event.key)) {
        event.preventDefault()
        this.zoomAt(center, 0.85)
      } else if (event.key === "-") {
        event.preventDefault()
        this.zoomAt(center, 1.18)
      } else if (event.key === "Home") {
        event.preventDefault()
        this.resetView()
      }
    }

    this.svg.addEventListener("wheel", this.onWheel, {passive: false})
    this.svg.addEventListener("pointerdown", this.onPointerDown)
    this.svg.addEventListener("pointermove", this.onPointerMove, {passive: false})
    this.svg.addEventListener("pointerup", this.onPointerUp)
    this.svg.addEventListener("pointercancel", this.onPointerUp)
    this.svg.addEventListener("touchmove", this.onTouchMove, {passive: false})
    this.svg.addEventListener("gesturestart", this.onGesture, {passive: false})
    this.svg.addEventListener("gesturechange", this.onGesture, {passive: false})
    this.svg.addEventListener("click", this.onClick, true)
    this.svg.addEventListener("keydown", this.onKeyDown)
    this.container.addEventListener("click", this.onControlClick)
    window.addEventListener("resize", this.onResize)
    this.resizeMarkers()
    this.positionInspector()
  },

  beforeUpdate() {
    this.viewport = {
      signature: this.waypointSignature(),
      viewBox: {
        x: this.viewBox.x,
        y: this.viewBox.y,
        width: this.viewBox.width,
        height: this.viewBox.height,
      },
    }
  },

  updated() {
    this.svg = this.el
    this.viewBox = this.svg.viewBox.baseVal

    if (this.viewport?.signature === this.waypointSignature()) {
      Object.assign(this.viewBox, this.viewport.viewBox)
      this.resizeMarkers()
    } else {
      this.initialViewBox = {
        x: this.viewBox.x,
        y: this.viewBox.y,
        width: this.viewBox.width,
        height: this.viewBox.height,
      }
      this.resizeMarkers()
    }

    window.requestAnimationFrame(() => this.positionInspector())
  },

  destroyed() {
    this.svg.removeEventListener("wheel", this.onWheel)
    this.svg.removeEventListener("pointerdown", this.onPointerDown)
    this.svg.removeEventListener("pointermove", this.onPointerMove)
    this.svg.removeEventListener("pointerup", this.onPointerUp)
    this.svg.removeEventListener("pointercancel", this.onPointerUp)
    this.svg.removeEventListener("touchmove", this.onTouchMove)
    this.svg.removeEventListener("gesturestart", this.onGesture)
    this.svg.removeEventListener("gesturechange", this.onGesture)
    this.svg.removeEventListener("click", this.onClick, true)
    this.svg.removeEventListener("keydown", this.onKeyDown)
    this.container.removeEventListener("click", this.onControlClick)
    window.removeEventListener("resize", this.onResize)
  },

  pointAt(clientX, clientY) {
    const point = this.svg.createSVGPoint()
    point.x = clientX
    point.y = clientY
    const mapPoint = point.matrixTransform(this.svg.getScreenCTM().inverse())
    return {x: mapPoint.x, y: mapPoint.y}
  },

  pinchState() {
    const [first, second] = [...this.pointers.values()]
    if (!first || !second) return null

    return {
      center: this.pointAt((first.x + second.x) / 2, (first.y + second.y) / 2),
      distance: Math.hypot(first.x - second.x, first.y - second.y),
    }
  },

  zoomAt(point, factor) {
    const width = Math.min(
      Math.max(this.viewBox.width * factor, this.initialViewBox.width / 20),
      this.initialViewBox.width * 8,
    )
    const height = Math.min(
      Math.max(this.viewBox.height * factor, this.initialViewBox.height / 20),
      this.initialViewBox.height * 8,
    )
    this.viewBox.x = point.x - (point.x - this.viewBox.x) * width / this.viewBox.width
    this.viewBox.y = point.y - (point.y - this.viewBox.y) * height / this.viewBox.height
    this.viewBox.width = width
    this.viewBox.height = height
    this.resizeMarkers()
    this.positionInspector()
  },

  resizeMarkers() {
    const matrix = this.svg.getScreenCTM()
    if (!matrix) return

    const pixelsPerUnit = Math.hypot(matrix.a, matrix.b)
    if (!pixelsPerUnit) return

    const markerScale = 12 / (6 * pixelsPerUnit)
    this.svg.querySelectorAll(".system-map-waypoint").forEach(marker => {
      const {x, y} = this.displayPosition(marker, pixelsPerUnit)
      const baseX = Number(marker.dataset.x)
      const baseY = Number(marker.dataset.y)
      const selectedScale = marker.classList.contains("selected") ? 1.15 : 1

      marker.setAttribute(
        "transform",
        `translate(${x} ${y}) scale(${markerScale * selectedScale}) translate(${-baseX} ${-baseY})`,
      )
    })

    this.resizeTransitRoutes(pixelsPerUnit)
  },

  displayPosition(marker, pixelsPerUnit) {
    const {x, y, orbitalOffsetX, orbitalOffsetY, orbitalDistance} = marker.dataset
    const distance = Number(orbitalDistance || 0) / pixelsPerUnit

    return {
      x: Number(x) + Number(orbitalOffsetX || 0) * distance,
      y: Number(y) + Number(orbitalOffsetY || 0) * distance,
    }
  },

  resizeTransitRoutes(pixelsPerUnit) {
    const markers = new Map(
      [...this.svg.querySelectorAll(".system-map-waypoint")]
        .map(marker => [marker.dataset.waypointSymbol, marker]),
    )

    this.svg.querySelectorAll(".system-map-transit-route").forEach(route => {
      const origin = markers.get(route.dataset.transitOrigin)
      const destination = markers.get(route.dataset.transitDestination)
      if (!origin || !destination) return

      const originPosition = this.displayPosition(origin, pixelsPerUnit)
      const destinationPosition = this.displayPosition(destination, pixelsPerUnit)
      route.setAttribute("x1", originPosition.x)
      route.setAttribute("y1", originPosition.y)
      route.setAttribute("x2", destinationPosition.x)
      route.setAttribute("y2", destinationPosition.y)
    })
  },

  positionInspector() {
    const inspector = this.container.querySelector("[data-map-inspector]")
    const marker = this.svg.querySelector(".system-map-waypoint.selected")
    if (!inspector) return

    if (window.matchMedia("(max-width: 640px)").matches) {
      inspector.style.removeProperty("left")
      inspector.style.removeProperty("top")
      return
    }

    const map = this.container.getBoundingClientRect()

    if (!marker) {
      inspector.style.left = "12px"
      inspector.style.top = "3.5rem"
      return
    }

    const target = marker.getBoundingClientRect()
    const panel = inspector.getBoundingClientRect()
    const left = Math.min(Math.max(target.left - map.left + target.width / 2 + 12, 12), map.width - panel.width - 12)
    const top = Math.min(Math.max(target.top - map.top + target.height / 2 + 12, 12), map.height - panel.height - 12)

    inspector.style.left = `${left}px`
    inspector.style.top = `${top}px`
  },

  resetView() {
    Object.assign(this.viewBox, this.initialViewBox)
    this.resizeMarkers()
    this.positionInspector()
  },

  waypointSignature() {
    return [...this.svg.querySelectorAll(".system-map-waypoint")]
      .map(waypoint => `${waypoint.dataset.waypointSymbol}:${waypoint.dataset.x}:${waypoint.dataset.y}`)
      .join("|")
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, SystemMap},
  dom: {
    onBeforeElUpdated(from, to) {
      if (from instanceof HTMLDetailsElement && to instanceof HTMLDetailsElement) {
        to.open = from.open
      }
    },
  },
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
