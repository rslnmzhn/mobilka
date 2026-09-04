final class SafWorkspaceReadSupport {
  const SafWorkspaceReadSupport();

  bool isUtf8Boundary(List<int> bytes, int offset) =>
      offset == 0 || offset == bytes.length || (bytes[offset] & 0xc0) != 0x80;
}
