import SwiftUI
#if canImport(GoogleCast)
import GoogleCast

// MARK: - CastButtonView (with SDK)
/// UIViewControllerRepresentable that renders a visible cast icon and on tap
/// triggers an off-screen GCKUICastButton to show the Cast dialog.
///
/// Why this approach:
/// - GCKUICastButton auto-hides and clears its icon before discovery completes,
///   leaving the button invisible.
/// - GCKCastContext.presentCastDialog() walks from the KEY WINDOW root VC, so
///   when called directly the dialog lands BEHIND the NowPlaying sheet.
/// - GCKUICastButton.triggersDefaultCastDialog walks the RESPONDER CHAIN instead,
///   finding CastButtonHostVC (which is inside the sheet) as the presenting VC,
///   so the dialog correctly appears on top.
///
/// Solution: always-visible UIButton with cast icon loaded from bundle;
/// on tap, fire the off-screen proxyButton so the SDK uses the responder chain.
struct CastButtonView: UIViewControllerRepresentable {
    var tintColor: UIColor = .white.withAlphaComponent(0.45)

    func makeUIViewController(context: Context) -> CastButtonHostVC {
        CastButtonHostVC()
    }

    func updateUIViewController(_ vc: CastButtonHostVC, context: Context) {
        vc.setTint(tintColor)
    }
}

// MARK: - CastButtonHostVC
final class CastButtonHostVC: UIViewController {
    private let visibleButton = UIButton(type: .system)
    // Off-screen GCKUICastButton: only used for its responder-chain-aware dialog
    // presentation. Placed far off-screen so it is never seen by the user.
    private let proxyButton = GCKUICastButton(frame: CGRect(x: -2000, y: -2000, width: 44, height: 44))

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        // Proxy: in the hierarchy so responder chain reaches this VC.
        proxyButton.triggersDefaultCastDialog = true
        proxyButton.isAccessibilityElement = false
        view.addSubview(proxyButton)

        // Visible button with cast-disconnected icon, always shown.
        visibleButton.setImage(castIcon(), for: .normal)
        visibleButton.tintColor = .white.withAlphaComponent(0.45)
        visibleButton.addTarget(self, action: #selector(castTapped), for: .touchUpInside)
        visibleButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(visibleButton)
        NSLayoutConstraint.activate([
            visibleButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            visibleButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            visibleButton.widthAnchor.constraint(equalTo: view.widthAnchor),
            visibleButton.heightAnchor.constraint(equalTo: view.heightAnchor),
        ])
    }

    func setTint(_ color: UIColor) {
        visibleButton.tintColor = color
    }

    @objc private func castTapped() {
        // Trigger via the proxy GCKUICastButton so the SDK finds CastButtonHostVC
        // in the responder chain and presents the dialog on top of the sheet.
        proxyButton.sendActions(for: .touchUpInside)
    }

    private func castIcon() -> UIImage? {
        for (bundleName, imageName) in [
            ("GoogleCastCoreResources", "cast_disconnected_24pt"),
            ("GoogleCastOptionalUIResources", "cast_on0"),
        ] {
            guard let url = Bundle.main.url(forResource: bundleName, withExtension: "bundle"),
                  let bundle = Bundle(url: url) else { continue }
            if let img = UIImage(named: imageName, in: bundle, compatibleWith: nil) { return img }
            if let iconURL = bundle.url(forResource: imageName, withExtension: "png", subdirectory: "Icons"),
               let data = try? Data(contentsOf: iconURL),
               let img = UIImage(data: data) { return img }
        }
        return UIImage(systemName: "tv")
    }
}

#else

// MARK: - CastButtonView (stub - SDK not installed)
struct CastButtonView: View {
    var tintColor: Color = .white.opacity(0.2)
    var body: some View {
        Image(systemName: "tv")
            .foregroundStyle(tintColor)
    }
}

#endif
