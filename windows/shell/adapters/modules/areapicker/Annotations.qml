pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import Quickshell
import "EditorLogic.js" as Logic

// The annotation layer: the committed strokes and the one being drawn, rendered
// as QtQuick Shapes. It sits over the frozen frame inside the item that is
// exported, so what is saved is exactly what is drawn. It is as large as the
// selection and clips to it, as the classic tool does.
//
// The rules for what each stroke looks like are in EditorLogic.js (primitives).
// This file only turns that list into Shapes.
Item {
    id: root

    // Committed strokes, oldest first, and the stroke being drawn.
    property var strokes: []
    property var draft: null
    // Changes whenever the draft's points change.
    property int revision

    clip: true

    Repeater {
        model: ScriptModel {
            values: root.strokes
        }

        StrokeView {
            required property var modelData

            stroke: modelData
        }
    }

    StrokeView {
        objectName: "annotationDraft"
        stroke: root.draft ? root.draft.stroke : null
        revision: root.revision
    }

    // One stroke. The Shapes are kept while the number of primitives stays the
    // same, so drawing a long stroke updates paths and does not create items.
    component StrokeView: Item {
        id: view

        property var stroke: null
        property int revision
        readonly property var list: {
            view.revision;
            return stroke ? Logic.primitives(stroke) : [];
        }

        anchors.fill: parent

        Repeater {
            model: view.list.length

            PrimitiveView {
                required property int index

                primitive: view.list[index]
            }
        }
    }

    component PrimitiveView: Shape {
        id: shape

        property var primitive: null
        readonly property string kind: primitive ? primitive.kind : ""
        readonly property bool isLine: kind === "polyline"
        readonly property bool isPolygon: kind === "polygon"
        readonly property bool isEllipse: kind === "ellipse"
        readonly property bool isDot: kind === "dot"

        function points(): var {
            return (isLine || isPolygon) ? primitive.points.map(p => Qt.point(p.x, p.y)) : [];
        }

        objectName: "annotationPrimitive"
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeColor: shape.isLine ? Qt.alpha(shape.primitive.color, shape.primitive.alpha) : "transparent"
            strokeWidth: shape.isLine ? shape.primitive.width : -1
            fillColor: shape.isPolygon ? shape.primitive.color : "transparent"
            capStyle: shape.isLine && shape.primitive.cap === "square" ? ShapePath.SquareCap : ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin

            PathPolyline {
                path: shape.points()
            }
        }

        // A circle stroke is an outlined ellipse. A pencil click is a filled dot.
        ShapePath {
            strokeColor: shape.isEllipse ? shape.primitive.color : "transparent"
            strokeWidth: shape.isEllipse ? shape.primitive.width : -1
            fillColor: shape.isDot ? shape.primitive.color : "transparent"

            PathAngleArc {
                centerX: shape.isEllipse || shape.isDot ? shape.primitive.cx : 0
                centerY: shape.isEllipse || shape.isDot ? shape.primitive.cy : 0
                radiusX: shape.isEllipse ? shape.primitive.rx : (shape.isDot ? shape.primitive.r : 0)
                radiusY: shape.isEllipse ? shape.primitive.ry : (shape.isDot ? shape.primitive.r : 0)
                startAngle: 0
                sweepAngle: 360
            }
        }
    }
}
