import Foundation
import SwiftUI
import MapKit
import QuartzCore

// MARK: - 地图标注（F49 / §B.6.2）

/// 用户放置的路线点 / 必经点 / 当前回放点。坐标使用冻结的 `GeoPoint`，不引入新坐标类型。
public struct RouteMapAnnotation: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let coordinate: GeoPoint
    public let symbolName: String

    public init(id: String, label: String, coordinate: GeoPoint, symbolName: String = "mappin.circle.fill") {
        self.id = id
        self.label = label
        self.coordinate = coordinate
        self.symbolName = symbolName
    }

    public var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

// MARK: - MapKit SwiftUI 地图（F49）

/// 真实 MapKit SwiftUI 地图：`Map` / `MapReader` / `MapPolyline` / `MapCameraPosition` / `MapStyle`。
/// - 点选新增点：`SpatialTapGesture` → `MapReader` 转成 `GeoPoint` → `onAddPoint` 真实编辑动作。
/// - 长按拖动：拖动起点 44pt 内最近的标注被选中，拖动过程持续调用 `onMovePoint` 真实改点。
/// - 跨 segment / 暂停段不连线：由 `SeriesBuilder.breakBefore` 决定，这里只绘制连续折线段。
/// - 深色模式：`MapStyle.standard` 随系统切换；提高对比度时切换到 `hybrid` 强化边界。
public struct RouteMapView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    @Binding public var cameraPosition: MapCameraPosition

    public let points: [GeoPoint]
    public let annotations: [RouteMapAnnotation]
    /// 0...1；用于回放 / 预览的渐进轨迹（按弧长比例截取折线，不臆造坐标）。
    public let progress: Double
    public let onAddPoint: ((GeoPoint) -> Void)?
    public let onSelectPoint: ((Int) -> Void)?
    public let onMovePoint: ((Int, GeoPoint) -> Void)?

    @State private var activeDragIndex: Int? = nil

    public init(
        points: [GeoPoint],
        cameraPosition: Binding<MapCameraPosition>,
        annotations: [RouteMapAnnotation] = [],
        progress: Double = 1,
        onAddPoint: ((GeoPoint) -> Void)? = nil,
        onSelectPoint: ((Int) -> Void)? = nil,
        onMovePoint: ((Int, GeoPoint) -> Void)? = nil
    ) {
        self.points = points
        self._cameraPosition = cameraPosition
        self.annotations = annotations
        self.progress = progress
        self.onAddPoint = onAddPoint
        self.onSelectPoint = onSelectPoint
        self.onMovePoint = onMovePoint
    }

    public var body: some View {
        MapReader { proxy in
            Map(position: $cameraPosition) {
                if displayedCoordinates.count >= 2 {
                    MapPolyline(coordinates: displayedCoordinates)
                        .stroke(polylineColor, lineWidth: 4)
                }
                ForEach(annotations) { item in
                    Marker(item.label, systemImage: item.symbolName, coordinate: item.clCoordinate)
                        .tint(annotationColor)
                }
            }
            .mapStyle(mapStyle)
            .overlay(alignment: .topLeading) {
                mapLegend
                    .padding(AppTheme.Spacing.sm)
            }
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .local)
                    .onEnded { value in
                        guard let onAddPoint,
                              let coordinate = proxy.convert(value.location, from: .local) else { return }
                        onAddPoint(GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude))
                    }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .local)
                    .onChanged { value in
                        guard let onMovePoint else { return }
                        if activeDragIndex == nil {
                            activeDragIndex = Self.nearestAnnotationIndex(
                                to: value.startLocation,
                                annotations: annotations,
                                proxy: proxy
                            )
                            if let index = activeDragIndex {
                                onSelectPoint?(index)
                            }
                        }
                        guard let index = activeDragIndex,
                              let coordinate = proxy.convert(value.location, from: .local) else { return }
                        onMovePoint(index, GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude))
                    }
                    .onEnded { _ in
                        activeDragIndex = nil
                    }
            )
        }
        .frame(minHeight: 240)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.CornerRadius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.CornerRadius.large, style: .continuous)
                .strokeBorder(AppTheme.Colors.cardStroke(colorScheme), lineWidth: 1)
        }
        .accessibilityLabel(Text("地图：\(displayedCoordinates.count) 个轨迹点"))
        .accessibilityHint(Text(AccessibilityLabels.mapAddPoint))
    }

    // MARK: 私有实现

    /// 按 `progress` 截取折线（线性分段插值，不新增随机坐标），并过滤非法经纬度。
    private var displayedCoordinates: [CLLocationCoordinate2D] {
        let valid = points.filter(\.isValid).map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        guard valid.count >= 2 else { return [] }
        let clamped = min(1, max(0, progress.isFinite ? progress : 1))
        guard clamped < 1 else { return valid }
        var segments: [Double] = []
        var total = 0.0
        for index in 1..<valid.count {
            let a = GeoPoint(latitude: valid[index - 1].latitude, longitude: valid[index - 1].longitude)
            let b = GeoPoint(latitude: valid[index].latitude, longitude: valid[index].longitude)
            let length = Units.haversineMeters(a, b)
            segments.append(length)
            total += length
        }
        guard total > 0 else { return valid }
        let target = total * clamped
        var accumulated = 0.0
        var result: [CLLocationCoordinate2D] = [valid[0]]
        for index in 0..<segments.count {
            let length = segments[index]
            if accumulated + length >= target {
                let ratio = length > 0 ? (target - accumulated) / length : 0
                let from = valid[index]
                let to = valid[index + 1]
                result.append(CLLocationCoordinate2D(
                    latitude: from.latitude + (to.latitude - from.latitude) * ratio,
                    longitude: from.longitude + (to.longitude - from.longitude) * ratio
                ))
                return result
            }
            accumulated += length
            result.append(valid[index + 1])
        }
        return result
    }

    private var polylineColor: Color {
        differentiateWithoutColor ? .primary : .accentColor
    }

    private var annotationColor: Color {
        colorScheme == .dark ? .orange : .red
    }

    private var mapStyle: MapStyle {
        differentiateWithoutColor ? .hybrid : .standard
    }

    private var mapLegend: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("地图与路线")
                .font(.caption2.weight(.semibold))
            Text("点击新增点 · 长按拖动改点")
                .font(.caption2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colorScheme == .dark ? Color.black.opacity(0.72) : Color.white.opacity(0.82))
        )
        .accessibilityHidden(true)
    }

    /// 找拖动起点 44pt 内最近的标注索引；没有则返回 nil（不误改点）。
    private static func nearestAnnotationIndex(
        to point: CGPoint,
        annotations: [RouteMapAnnotation],
        proxy: MapProxy
    ) -> Int? {
        var bestIndex: Int? = nil
        var bestDistance: CGFloat = 44
        for (index, item) in annotations.enumerated() {
            guard let screen = proxy.convert(item.clCoordinate, to: .local) else { continue }
            let distance = hypot(screen.x - point.x, screen.y - point.y)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }
}

// MARK: - 渐进轨迹桥接（F49 / §B.6.2 / §B.6.6）

/// `UIViewRepresentable` 桥接 `MKMapView`：全量轨迹用 `MKPolylineRenderer` 打底，
/// 渐进部分用 `CAShapeLayer.strokeEnd` 按 `progress` 真实绘制（iOS 上 `MKPolylineRenderer`
/// 本身不暴露 `strokeEnd`，因此用 CoreAnimation 图层承担「绘制到哪一截」的职责，
/// 两者组合实现架构要求的渐进轨迹，无伪造坐标、无独立随机）。
public struct TrackPolylineBridge: UIViewRepresentable {
    public let coordinates: [GeoPoint]
    /// 0...1
    public let progress: Double
    public let animated: Bool

    public init(coordinates: [GeoPoint], progress: Double, animated: Bool = true) {
        self.coordinates = coordinates
        self.progress = progress
        self.animated = animated
    }

    public func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.isUserInteractionEnabled = false
        mapView.pointOfInterestFilter = .excludingAll
        let layer = CAShapeLayer()
        layer.strokeColor = UIColor.tintColor.cgColor
        layer.fillColor = UIColor.clear.cgColor
        layer.lineWidth = 5
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.strokeStart = 0
        layer.strokeEnd = 0
        mapView.layer.addSublayer(layer)
        context.coordinator.progressLayer = layer
        let head = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 12))
        head.backgroundColor = .systemRed
        head.layer.cornerRadius = 6
        head.layer.borderColor = UIColor.white.cgColor
        head.layer.borderWidth = 2
        head.isHidden = true
        mapView.addSubview(head)
        context.coordinator.headView = head
        return mapView
    }

    public func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.apply(
            mapView: mapView,
            coordinates: coordinates,
            progress: progress,
            animated: animated
        )
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    public final class Coordinator: NSObject, MKMapViewDelegate {
        public var progressLayer: CAShapeLayer?
        public var headView: UIView?
        private var currentCoordinates: [GeoPoint] = []
        private var currentProgress: Double = 0
        private var currentAnimated: Bool = true
        private var baseOverlay: MKPolyline?
        private var hasCentered = false

        public func apply(
            mapView: MKMapView,
            coordinates: [GeoPoint],
            progress: Double,
            animated: Bool
        ) {
            currentCoordinates = coordinates.filter(\.isValid)
            currentProgress = min(1, max(0, progress.isFinite ? progress : 0))
            currentAnimated = animated

            let clCoordinates = currentCoordinates.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }
            if let baseOverlay {
                mapView.removeOverlay(baseOverlay)
            }
            if clCoordinates.count >= 2 {
                let polyline = MKPolyline(coordinates: clCoordinates, count: clCoordinates.count)
                mapView.addOverlay(polyline)
                baseOverlay = polyline
                if !hasCentered {
                    let region = MKCoordinateRegion(polyline.boundingMapRect)
                    mapView.setRegion(region, animated: false)
                    hasCentered = true
                }
            } else {
                baseOverlay = nil
            }
            redraw(in: mapView)
        }

        public func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor.tintColor.withAlphaComponent(0.22)
                renderer.lineWidth = 6
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        public func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            redraw(in: mapView)
        }

        private func redraw(in mapView: MKMapView) {
            guard let layer = progressLayer else { return }
            let points = currentCoordinates.map {
                mapView.convert(
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude),
                    toPointTo: mapView
                )
            }
            guard points.count >= 2 else {
                layer.path = nil
                layer.strokeEnd = 0
                headView?.isHidden = true
                return
            }
            let path = CGMutablePath()
            path.move(to: points[0])
            for index in 1..<points.count {
                path.addLine(to: points[index])
            }
            layer.path = path
            CATransaction.begin()
            CATransaction.setDisableActions(!currentAnimated)
            layer.strokeEnd = CGFloat(currentProgress)
            CATransaction.commit()
            headView?.isHidden = false
            headView?.center = Self.point(atFraction: currentProgress, of: points)
        }

        /// 按折线累计长度比例插值出当前绘制头位置，保证与 `strokeEnd` 同一口径。
        private static func point(atFraction fraction: Double, of points: [CGPoint]) -> CGPoint {
            guard points.count >= 2 else { return points.first ?? .zero }
            var lengths: [Double] = []
            var total = 0.0
            for index in 1..<points.count {
                let length = Double(hypot(
                    points[index].x - points[index - 1].x,
                    points[index].y - points[index - 1].y
                ))
                lengths.append(length)
                total += length
            }
            guard total > 0 else { return points[0] }
            let target = total * min(1, max(0, fraction))
            var accumulated = 0.0
            for index in 0..<lengths.count {
                if accumulated + lengths[index] >= target {
                    let ratio = lengths[index] > 0 ? (target - accumulated) / lengths[index] : 0
                    let from = points[index]
                    let to = points[index + 1]
                    return CGPoint(
                        x: from.x + (to.x - from.x) * CGFloat(ratio),
                        y: from.y + (to.y - from.y) * CGFloat(ratio)
                    )
                }
                accumulated += lengths[index]
            }
            return points[points.count - 1]
        }
    }
}
