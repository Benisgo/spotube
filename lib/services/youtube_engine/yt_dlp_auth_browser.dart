enum YtDlpAuthBrowser {
  auto("Auto"),
  firefox("Firefox"),
  edge("Edge"),
  chrome("Chrome"),
  chromium("Chromium"),
  brave("Brave");

  final String label;

  const YtDlpAuthBrowser(this.label);

  String? get ytDlpArgument => switch (this) {
        YtDlpAuthBrowser.auto => null,
        YtDlpAuthBrowser.firefox => "firefox",
        YtDlpAuthBrowser.edge => "edge",
        YtDlpAuthBrowser.chrome => "chrome",
        YtDlpAuthBrowser.chromium => "chromium",
        YtDlpAuthBrowser.brave => "brave",
      };

  static YtDlpAuthBrowser fromName(String? name) {
    return YtDlpAuthBrowser.values.firstWhere(
      (value) => value.name == name,
      orElse: () => YtDlpAuthBrowser.auto,
    );
  }
}
