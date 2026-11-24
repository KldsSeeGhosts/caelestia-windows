pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import Quickshell
import "EditorLogic.js" as Logic

// The annotation layer: the committed strokes and the one being drawn, rendered
// as QtQuick Shapes, text and pixelated regions. It sits over the frozen frame
// inside the item that is exported, so what is saved is exactly what is drawn.
// It is as large as the selection and clips to it, as the classic tool does.
//
// The rules for what each stroke looks like are in EditorLogic.js (primitives).
// This file only turns that list into items.
Item {
    id: root

    // Committed strokes, oldest first, and the stroke being drawn.
    property var strokes: []
    property var draft: null
    // Changes whenever the draft's points change.
    property int revision
    // An item with exactly the pixels under this layer, cropped to the same
    // size. Blur primitives sample it.
    property Item base: null

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

    // One stroke. The items are kept while the number of primitives stays the
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

    component PrimitiveView: Item {
        id: primitiveItem

        property var primitive: null
        readonly property string kind: primitive ? primitive.kind : ""
        readonly property bool isLine: kind === "polyline"
        readonly property bool isPolygon: kind === "polygon"
        readonly property bool isEllipse: kind === "ellipse"
        readonly property bool isDot: kind === "dot"
        readonly property bool isText: kind === "text"
        readonly property bool isStep: kind === "step"
        readonly property bool isBlur: kind === "blur"
        readonly property bool isShape: isLine || isPolygon || isEllipse || isDot

        function points(): var {
            return (isLine || isPolygon) ? primitive.points.map(p => Qt.point(p.x, p.y)) : [];
        }

        objectName: "annotationPrimitive"
        anchors.fill: parent

        Shape {
            anchors.fill: parent
            visible: primitiveItem.isShape
            preferredRendererType: Shape.CurveRenderer

            ShapePath {
                strokeColor: primitiveItem.isLine ? Qt.alpha(primitiveItem.primitive.color, primitiveItem.primitive.alpha) : "transparent"
                strokeWidth: primitiveItem.isLine ? primitiveItem.primitive.width : -1
                fillColor: primitiveItem.isPolygon ? primitiveItem.primitive.color : "transparent"
                capStyle: primitiveItem.isLine && primitiveItem.primitive.cap === "square" ? ShapePath.SquareCap : ShapePath.RoundCap
                joinStyle: ShapePath.RoundJoin

                PathPolyline {
                    path: primitiveItem.points()
                }
            }

            // A circle stroke is an outlined or filled ellipse. A pencil click is a filled dot.
            ShapePath {
                strokeColor: primitiveItem.isEllipse && !primitiveItem.primitive.fill ? primitiveItem.primitive.color : "transparent"
                strokeWidth: primitiveItem.isEllipse && !primitiveItem.primitive.fill ? primitiveItem.primitive.width : -1
                fillColor: primitiveItem.isDot || (primitiveItem.isEllipse && primitiveItem.primitive.fill) ? primitiveItem.primitive.color : "transparent"

                PathAngleArc {
                    centerX: primitiveItem.isEllipse || primitiveItem.isDot ? primitiveItem.primitive.cx : 0
                    centerY: primitiveItem.isEllipse || primitiveItem.isDot ? primitiveItem.primitive.cy : 0
                    radiusX: primitiveItem.isEllipse ? primitiveItem.primitive.rx : (primitiveItem.isDot ? primitiveItem.primitive.r : 0)
                    radiusY: primitiveItem.isEllipse ? primitiveItem.primitive.ry : (primitiveItem.isDot ? primitiveItem.primitive.r : 0)
                    startAngle: 0
                    sweepAngle: 360
                }
            }
        }

        Text {
            visible: primitiveItem.isText
            x: primitiveItem.isText ? primitiveItem.primitive.x : 0
            y: primitiveItem.isText ? primitiveItem.primitive.y : 0
            text: primitiveItem.isText ? primitiveItem.primitive.text : ""
            color: primitiveItem.isText ? primitiveItem.primitive.color : "transparent"
            font.pixelSize: primitiveItem.isText ? primitiveItem.primitive.pixelSize : 1
        }

        Item {
            id: badge

            visible: primitiveItem.isStep
            x: primitiveItem.isStep ? primitiveItem.primitive.cx - primitiveItem.primitive.r : 0
            y: primitiveItem.isStep ? primitiveItem.primitive.cy - primitiveItem.primitive.r : 0
            width: primitiveItem.isStep ? primitiveItem.primitive.r * 2 : 0
            height: width

            Shape {
                anchors.fill: parent

                ShapePath {
                    strokeColor: "transparent"
                    fillColor: primitiveItem.isStep ? primitiveItem.primitive.color : "transparent"

                    PathAngleArc {
                        centerX: badge.width / 2
                        centerY: badge.height / 2
                        radiusX: badge.width / 2
                        radiusY: badge.height / 2
                        startAngle: 0
                        sweepAngle: 360
                    }
                }
            }

            Text {
                anchors.fill: parent
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: primitiveItem.isStep ? primitiveItem.primitive.label : ""
                color: primitiveItem.isStep ? primitiveItem.primitive.textColor : "transparent"
                font.pixelSize: primitiveItem.isStep ? primitiveItem.primitive.pixelSize : 1
            }
        }

        Item {
            visible: primitiveItem.isBlur
            x: primitiveItem.isBlur ? primitiveItem.primitive.x : 0
            y: primitiveItem.isBlur ? primitiveItem.primitive.y : 0
            width: primitiveItem.isBlur ? primitiveItem.primitive.width : 0
            height: primitiveItem.isBlur ? primitiveItem.primitive.height : 0
            clip: true

            ShaderEffect {
                x: primitiveItem.isBlur ? -primitiveItem.primitive.x : 0
                y: primitiveItem.isBlur ? -primitiveItem.primitive.y : 0
                width: primitiveItem.width
                height: primitiveItem.height
                property var source: root.base
                fragmentShader: "
                    #version 440
                    layout(location = 0) in vec2 qt_TexCoord0;
                    layout(location = 0) out vec4 fragColor;
                    layout(std140, binding = 0) uniform buf {
                        mat4 qt_Matrix;
                        float qt_Opacity;
                    };
                    layout(binding = 1) uniform sampler2D source;
                    void main() {
                        vec2 texel = vec2(20.0) / vec2(textureSize(source, 0));
                        vec2 uv = (floor(qt_TexCoord0 / texel) + vec2(0.5)) * texel;
                        fragColor = texture(source, clamp(uv, vec2(0.0), vec2(1.0))) * qt_Opacity;
                    }"
            }
        }
    }
}
