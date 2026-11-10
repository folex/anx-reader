/// Actual request lifecycle, scoped to one book/account/request.
enum AssistantActivity {
  idle,
  connecting,
  thinking,
  tools,
  disconnected,
  error
}
