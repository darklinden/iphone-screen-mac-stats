import UIKit

/// 设置页（M5）：服务器 IP / 端口输入 + 「测试连接」+ 保存。
///
/// 规格见 docs/design.md 的「设置入口」：
/// - 入口是「长按 2 秒整个屏幕」，手势挂在 `DashboardViewController` 上；
/// - 字段：服务器 IP、端口、「测试连接」；
/// - 配置**只经** `ServerConfig` 读写 `UserDefaults`，本文件不出现键名字面量；
/// - **必须在主线程写** `UserDefaults`——写入会同步投递
///   `UserDefaults.didChangeNotification`，而 `DashboardViewController` 在该通知里
///   重读配置并同步碰 UIKit；
/// - 「测试连接」用**输入框里的当前值**（不是已保存的值）拉一次 `GET /api/stats`，
///   超时 3 秒（比轮询的 0.8 秒长，因为这是用户手动触发的一次性动作），
///   失败原因要能区分超时 / 连接被拒 / 非 200 / 响应无法解析。
///
/// 布局按横屏 667 × 375pt 设计：目标机横屏只有 375pt 高，键盘弹起约占 160pt，
/// 所以整个表单放在 `UIScrollView` 里，键盘出现时把 `contentInset.bottom` 顶到
/// 键盘上沿，并把正在编辑的控件滚进可视区——保证两个输入框与「测试连接」
/// 按钮在键盘弹起时仍然可见可点。
final class SettingsViewController: UIViewController {

    // MARK: - 控件

    private let scrollView = UIScrollView()
    private let formStack = UIStackView()
    private let hostField = UITextField()
    private let portField = UITextField()
    private let testButton = UIButton(type: .system)
    private let testSpinner = UIActivityIndicatorView(style: .medium)
    private let resultLabel = UILabel()
    private let saveButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)

    // MARK: - 测试连接

    /// 「测试连接」的超时（design.md：3 秒）
    private let testTimeout: TimeInterval = 3
    private let testSession: URLSession
    private var testTask: URLSessionDataTask?

    /// 当前正在编辑的输入框（键盘弹出时滚到它）
    private weak var activeField: UITextField?

    // MARK: - 生命周期

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        // 与 StatsPoller 同理：不等待网络可用，否则 3 秒超时不会按预期触发
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        testSession = URLSession(configuration: configuration)

        super.init(nibName: nil, bundle: nil)
        // 全屏呈现：横屏只有 375pt 高，pageSheet 的卡片内缩会让键盘避让变得不可控
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark
        // 注意：本页**不碰** `isIdleTimerDisabled`，常亮开关只属于副屏（DashboardViewController）

        buildForm()
        prefillFromServerConfig()

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        testTask?.cancel()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        testTask?.cancel()
    }

    /// 设置页也是横屏、也不显示状态栏（AppDelegate 已全局锁横屏）
    override var prefersStatusBarHidden: Bool { true }

    // MARK: - 布局

    private func buildForm() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        view.addSubview(scrollView)

        formStack.axis = .vertical
        formStack.spacing = 10
        formStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(formStack)

        // 标题行：左「设置」，右「关闭」
        let titleLabel = UILabel()
        titleLabel.text = "设置"
        titleLabel.textColor = .white
        titleLabel.font = .boldSystemFont(ofSize: 20)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        closeButton.setTitle("关闭", for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 17)
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        closeButton.setContentHuggingPriority(.required, for: .horizontal)

        let headerRow = UIStackView(arrangedSubviews: [titleLabel, closeButton])
        headerRow.axis = .horizontal
        headerRow.alignment = .center

        // 服务器 IP
        // placeholder 只做格式提示，**不是默认值**——host 一律由用户填，代码里没有任何兜底 IP。
        // 故这里写「例如」，不写某个具体地址：Mac 换网段不该让源码变成过期信息。
        configure(hostField, placeholder: "例如 192.168.1.10")
        hostField.keyboardType = .URL
        hostField.autocapitalizationType = .none
        hostField.autocorrectionType = .no
        hostField.spellCheckingType = .no
        hostField.textContentType = .URL
        hostField.returnKeyType = .next
        hostField.delegate = self
        hostField.addTarget(self, action: #selector(fieldEditingBegan(_:)), for: .editingDidBegin)

        // 端口
        configure(portField, placeholder: String(ServerConfig.defaultPort))
        portField.keyboardType = .numberPad
        portField.textContentType = nil
        portField.delegate = self
        portField.addTarget(self, action: #selector(fieldEditingBegan(_:)), for: .editingDidBegin)

        let hostRow = labeledRow(title: "服务器 IP", field: hostField)
        let portRow = labeledRow(title: "端口", field: portField)

        // 「测试连接」+ 转圈
        testButton.setTitle("测试连接", for: .normal)
        testButton.titleLabel?.font = .systemFont(ofSize: 16)
        testButton.setTitleColor(.white, for: .normal)
        testButton.backgroundColor = .systemBlue
        testButton.layer.cornerRadius = 6
        testButton.addTarget(self, action: #selector(testConnection), for: .touchUpInside)
        testButton.heightAnchor.constraint(equalToConstant: 36).isActive = true

        testSpinner.color = .lightGray
        testSpinner.hidesWhenStopped = true

        let testRow = UIStackView(arrangedSubviews: [testButton, testSpinner])
        testRow.axis = .horizontal
        testRow.spacing = 8
        testRow.alignment = .center

        // 结果文案：多行，成功 / 失败都带简短原因
        resultLabel.textColor = .lightGray
        resultLabel.font = .systemFont(ofSize: 14)
        resultLabel.numberOfLines = 0
        resultLabel.text = "点「测试连接」用输入框里的地址拉一次 /api/stats"

        // 保存
        saveButton.setTitle("保存", for: .normal)
        saveButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        saveButton.setTitleColor(.white, for: .normal)
        saveButton.backgroundColor = .systemGreen
        saveButton.layer.cornerRadius = 6
        saveButton.addTarget(self, action: #selector(save), for: .touchUpInside)
        saveButton.heightAnchor.constraint(equalToConstant: 36).isActive = true

        for row in [headerRow, hostRow, portRow, testRow, resultLabel, saveButton] as [UIView] {
            formStack.addArrangedSubview(row)
        }

        // 背景点击收起键盘；delegate 把输入框 / 按钮自己的点击排除掉，
        // 否则点输入框的同一拍就会把刚拿到的焦点收掉、键盘闪一下就没
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        view.addGestureRecognizer(tap)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            formStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 10),
            formStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            formStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            formStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -10),
            formStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32),
        ])
    }

    private func configure(_ field: UITextField, placeholder: String) {
        field.placeholder = placeholder
        field.textColor = .white
        field.tintColor = .systemBlue
        field.font = .systemFont(ofSize: 16)
        field.keyboardAppearance = .dark
        field.backgroundColor = UIColor(white: 0.13, alpha: 1)
        field.layer.cornerRadius = 6
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 34))
        field.leftViewMode = .always
        field.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 34))
        field.rightViewMode = .always
        field.heightAnchor.constraint(equalToConstant: 34).isActive = true
        // 数字键盘没有 Return 键，给两个输入框都挂「完成」工具条
        field.inputAccessoryView = makeAccessoryToolbar()
    }

    private func labeledRow(title: String, field: UITextField) -> UIStackView {
        let label = UILabel()
        label.text = title
        label.textColor = .lightGray
        label.font = .systemFont(ofSize: 15)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: 82).isActive = true

        let row = UIStackView(arrangedSubviews: [label, field])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        return row
    }

    private func makeAccessoryToolbar() -> UIToolbar {
        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        toolbar.items = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(dismissKeyboard)),
        ]
        return toolbar
    }

    /// 预填：已保存的配置优先；未配置时端口给缺省值
    private func prefillFromServerConfig() {
        if let config = ServerConfig.load() {
            hostField.text = config.host
            portField.text = String(config.port)
        } else {
            hostField.text = ""
            portField.text = String(ServerConfig.defaultPort)
        }
    }

    // MARK: - 键盘避让

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let keyboardFrame = view.convert(endFrame, from: nil)
        let overlap = max(0, view.bounds.maxY - keyboardFrame.minY)
        scrollView.contentInset.bottom = overlap
        scrollView.verticalScrollIndicatorInsets.bottom = overlap
        if let active = activeField {
            ensureVisible(active, animated: true)
        }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        scrollView.contentInset.bottom = 0
        scrollView.verticalScrollIndicatorInsets.bottom = 0
    }

    @objc private func fieldEditingBegan(_ field: UITextField) {
        activeField = field
        ensureVisible(field, animated: true)
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    private func ensureVisible(_ target: UIView, animated: Bool) {
        let rect = target.convert(target.bounds, to: scrollView).insetBy(dx: 0, dy: -12)
        scrollView.scrollRectToVisible(rect, animated: animated)
    }

    // MARK: - 测试连接

    @objc private func testConnection() {
        view.endEditing(true)

        let host = (hostField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            showResult("失败：服务器 IP 不能为空", color: .systemRed)
            return
        }
        guard let port = parsedPort() else {
            showResult("失败：端口必须是 1–65535 的整数", color: .systemRed)
            return
        }
        guard let url = URL(string: "http://\(host):\(port)/api/stats") else {
            showResult("失败：地址非法（host 含 URL 不允许的字符）", color: .systemRed)
            return
        }

        testTask?.cancel()
        setTesting(true)
        showResult("测试中… \(url.absoluteString)", color: .lightGray)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = testTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        testTask = testSession.dataTask(with: request) { [weak self] data, response, error in
            // 分类是纯函数，不碰 UI，先算好再回主线程展示
            let outcome = SettingsViewController.classify(data: data, response: response, error: error)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.setTesting(false)
                self.show(outcome)
            }
        }
        testTask?.resume()
    }

    /// 测试连接的结果（失败文案就是排障线索，必须带原因）
    private enum TestOutcome {
        case success(StatsResponse)
        case failure(String)
    }

    private static func classify(data: Data?, response: URLResponse?, error: Error?) -> TestOutcome {
        if let error = error {
            guard let urlError = error as? URLError else {
                return .failure("失败：\(error.localizedDescription)")
            }
            switch urlError.code {
            case .timedOut:
                return .failure("失败：超时（3 秒内无响应）")
            case .cannotConnectToHost:
                return .failure("失败：连接被拒（该端口没有服务监听，或被防火墙拦下）")
            case .cannotFindHost:
                return .failure("失败：无法解析主机名")
            case .notConnectedToInternet:
                return .failure("失败：本机网络不可用")
            case .networkConnectionLost:
                return .failure("失败：连接中断")
            case .unsupportedURL, .badURL:
                return .failure("失败：地址非法")
            default:
                return .failure("失败：网络错误 \(urlError.code.rawValue)（\(urlError.localizedDescription)）")
            }
        }
        guard let http = response as? HTTPURLResponse else {
            return .failure("失败：没有收到 HTTP 响应")
        }
        guard http.statusCode == 200 else {
            return .failure("失败：非 200（HTTP \(http.statusCode)）")
        }
        guard let data = data else {
            return .failure("失败：响应无法解析（响应体为空）")
        }
        do {
            let stats = try JSONDecoder().decode(StatsResponse.self, from: data)
            return .success(stats)
        } catch {
            // 只报「解析不了」，不把 Swift 的 DecodingError 全文倒进界面
            // （那会撑爆两行文案，对排障也没多出有用信息）
            return .failure("失败：响应无法解析（HTTP 200，但响应体不是协议里的 JSON）")
        }
    }

    private func show(_ outcome: TestOutcome) {
        switch outcome {
        case .success(let stats):
            let cpu = stats.cpu?.total.map { "\(Int(($0 * 100).rounded()))%" } ?? "--"
            let gpu = stats.gpu?.util.map { "\(Int(($0 * 100).rounded()))%" } ?? "--"
            showResult("成功：seq \(stats.seq)，CPU \(cpu)，GPU \(gpu)", color: .systemGreen)
        case .failure(let message):
            showResult(message, color: .systemRed)
        }
    }

    private func setTesting(_ testing: Bool) {
        testButton.isEnabled = !testing
        testButton.alpha = testing ? 0.6 : 1
        if testing {
            testSpinner.startAnimating()
        } else {
            testSpinner.stopAnimating()
        }
    }

    private func showResult(_ text: String, color: UIColor) {
        resultLabel.text = text
        resultLabel.textColor = color
        ensureVisible(resultLabel, animated: true)
    }

    // MARK: - 保存

    @objc private func save() {
        // 按钮 action 本身在主线程；UserDefaults 写入与 didChangeNotification 的
        // 重读路径都要求在主线程，这里不做异步派发。
        assert(Thread.isMainThread, "ServerConfig.save 必须在主线程调用")

        let host = (hostField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            showResult("保存失败：服务器 IP 不能为空（未写入）", color: .systemRed)
            return
        }
        guard let port = parsedPort() else {
            showResult("保存失败：端口必须是 1–65535 的整数（未写入，缺省 \(ServerConfig.defaultPort)）", color: .systemRed)
            return
        }

        ServerConfig(host: host, port: port).save()
        dismiss(animated: true)
    }

    /// 端口解析：空、非整数、越界都算非法（**不静默回落**，由调用方给出提示）
    private func parsedPort() -> Int? {
        let text = (portField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(text), (1...65535).contains(port) else { return nil }
        return port
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}

// MARK: - UIGestureRecognizerDelegate

extension SettingsViewController: UIGestureRecognizerDelegate {

    /// 落在输入框 / 按钮（`UIControl`）上的点击不触发「收起键盘」
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(touch.view is UIControl)
    }
}

// MARK: - UITextFieldDelegate

extension SettingsViewController: UITextFieldDelegate {

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === hostField {
            portField.becomeFirstResponder()
        } else {
            textField.resignFirstResponder()
        }
        return true
    }
}
