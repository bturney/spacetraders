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
    this.viewBox = this.svg.viewBox.baseVal
    this.pointers = new Map()
    this.lastPan = null
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
      this.svg.setPointerCapture(event.pointerId)
      this.pointers.set(event.pointerId, {x: event.clientX, y: event.clientY})
      this.lastPan = this.pointAt(event.clientX, event.clientY)
      this.lastPinch = this.pinchState()
    }

    this.onPointerMove = event => {
      if (!this.pointers.has(event.pointerId)) return

      this.pointers.set(event.pointerId, {x: event.clientX, y: event.clientY})
      const points = [...this.pointers.values()]

      if (points.length === 1 && this.lastPan) {
        const point = this.pointAt(event.clientX, event.clientY)
        this.viewBox.x -= point.x - this.lastPan.x
        this.viewBox.y -= point.y - this.lastPan.y
        this.lastPan = this.pointAt(event.clientX, event.clientY)
      } else if (points.length === 2) {
        const pinch = this.pinchState()

        if (this.lastPinch) {
          this.zoomAt(pinch.center, this.lastPinch.distance / Math.max(pinch.distance, 1))
        }

        this.lastPinch = this.pinchState()
      }
    }

    this.onPointerUp = event => {
      this.pointers.delete(event.pointerId)
      const [pointer] = this.pointers.values()
      this.lastPan = pointer ? this.pointAt(pointer.x, pointer.y) : null
      this.lastPinch = this.pinchState()
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
    this.svg.addEventListener("pointermove", this.onPointerMove)
    this.svg.addEventListener("pointerup", this.onPointerUp)
    this.svg.addEventListener("pointercancel", this.onPointerUp)
    this.svg.addEventListener("keydown", this.onKeyDown)
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
    }
  },

  destroyed() {
    this.svg.removeEventListener("wheel", this.onWheel)
    this.svg.removeEventListener("pointerdown", this.onPointerDown)
    this.svg.removeEventListener("pointermove", this.onPointerMove)
    this.svg.removeEventListener("pointerup", this.onPointerUp)
    this.svg.removeEventListener("pointercancel", this.onPointerUp)
    this.svg.removeEventListener("keydown", this.onKeyDown)
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
  },

  resizeMarkers() {
    const scale = Math.sqrt(
      (this.viewBox.width / this.initialViewBox.width) *
      (this.viewBox.height / this.initialViewBox.height),
    )

    this.svg.querySelectorAll(".system-map-waypoint").forEach(marker => {
      const {x, y} = marker.dataset
      marker.setAttribute(
        "transform",
        `translate(${x} ${y}) scale(${scale}) translate(${-x} ${-y})`,
      )
    })
  },

  resetView() {
    Object.assign(this.viewBox, this.initialViewBox)
    this.resizeMarkers()
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
