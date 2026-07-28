class InsufficientStorageException implements Exception {
  final int availableBytes;
  final int requiredBytes;

  const InsufficientStorageException({
    required this.availableBytes,
    required this.requiredBytes,
  });

  @override
  String toString() =>
      'Insufficient storage: $requiredBytes bytes required, '
      '$availableBytes bytes available';
}
