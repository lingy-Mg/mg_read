import 'dart:ffi';
import 'dart:io';

/// Runtime-owned wrapper around a Windows Job Object.
///
/// The Job is configured with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`. Once the
/// Flutter-owned handle closes (including when the Flutter process exits),
/// Windows terminates every process assigned to the Job and descendants created
/// by those processes after assignment. This is deliberately an internal
/// desktop launcher primitive, not a Flutter application integration API.
final class WindowsJobObject {
  WindowsJobObject._(this._kernel32, this._handle) {
    _finalizer.attach(
      this,
      _JobHandleFinalizer(_kernel32, _handle),
      detach: this,
    );
  }

  /// Win32 access-denied error; existence must not be mistaken for exit in tests.
  static const int _errorAccessDenied = 5;

  /// HeapAlloc flag that initializes the native structure before flags are set.
  static const int _heapZeroMemory = 0x00000008;

  /// JOBOBJECTINFOCLASS value for JOBOBJECT_EXTENDED_LIMIT_INFORMATION.
  static const int _jobObjectExtendedLimitInformation = 9;

  /// Limit flag that makes kernel cleanup happen when this owner closes its Job.
  static const int _jobObjectLimitKillOnJobClose = 0x00002000;

  /// Narrow process query right used only by the package-owned liveness test.
  static const int _processQueryLimitedInformation = 0x1000;

  /// Required access right to assign a child process to a Windows Job Object.
  static const int _processSetQuota = 0x0100;

  /// Required access right when assigning a process to a kill-on-close Job.
  static const int _processTerminate = 0x0001;

  /// Win32 GetExitCodeProcess marker for a process that is still running.
  static const int _stillActive = 259;

  /// Last-resort cleanup if an owner forgets to call [close] before collection.
  static final Finalizer<_JobHandleFinalizer> _finalizer =
      Finalizer<_JobHandleFinalizer>((state) {
        state.kernel32.closeHandleUnchecked(state.handle);
      });

  /// Bound native calls associated with this process's loaded kernel32 DLL.
  final _Kernel32 _kernel32;

  /// Owned Job handle, set to zero immediately after [close] transfers/releases it.
  int _handle;

  /// Creates an owned Job Object with `KILL_ON_JOB_CLOSE` configured before any
  /// child is assigned. This configuration is the kernel-enforced guarantee
  /// that a Flutter process exit also ends its Runtime child process tree.
  static WindowsJobObject create() {
    if (!Platform.isWindows) {
      throw const WindowsJobObjectException(
        'windows_job_object_unsupported',
        'Windows Job Object ownership is only available on Windows.',
      );
    }

    final kernel32 = _Kernel32.instance;
    final jobHandle = kernel32.createJobObject(_nullPointer, _nullPointer);
    if (jobHandle == 0) {
      throw kernel32.error('windows_job_object_create_failed');
    }

    final information = kernel32.heapAlloc(
      sizeOf<_JobObjectExtendedLimitInformation>(),
    );
    if (information.address == 0) {
      kernel32.closeHandleUnchecked(jobHandle);
      throw kernel32.error('windows_job_object_allocate_failed');
    }

    try {
      information
              .cast<_JobObjectExtendedLimitInformation>()
              .ref
              .basicLimitInformation
              .limitFlags =
          _jobObjectLimitKillOnJobClose;
      final configured = kernel32.setInformationJobObject(
        jobHandle,
        _jobObjectExtendedLimitInformation,
        information,
        sizeOf<_JobObjectExtendedLimitInformation>(),
      );
      if (!configured) {
        final error = kernel32.error('windows_job_object_configure_failed');
        kernel32.closeHandleUnchecked(jobHandle);
        throw error;
      }
    } finally {
      kernel32.heapFree(information);
    }

    return WindowsJobObject._(kernel32, jobHandle);
  }

  /// Assigns a just-started Runtime child process to this Job.
  ///
  /// This is deliberately separate from [create]: the child must be launched
  /// by Dart first, but assignment happens immediately before startup output is
  /// consumed. The desktop Runtime Core is prohibited from spawning child
  /// processes; any later descendant is nevertheless Job-owned automatically.
  /// No application process or arbitrary PID may use this API.
  void assignProcess(int processId) {
    if (_handle == 0) {
      throw const WindowsJobObjectException(
        'windows_job_object_closed',
        'The Windows Job Object is already closed.',
      );
    }
    if (processId <= 0) {
      throw const WindowsJobObjectException(
        'windows_job_object_invalid_process',
        'The Runtime child process id is invalid.',
      );
    }

    final processHandle = _kernel32.openProcess(
      _processSetQuota | _processTerminate | _processQueryLimitedInformation,
      processId,
    );
    if (processHandle == 0) {
      throw _kernel32.error('windows_job_object_open_process_failed');
    }

    try {
      if (!_kernel32.assignProcessToJobObject(_handle, processHandle)) {
        throw _kernel32.error('windows_job_object_assign_failed');
      }
    } finally {
      _kernel32.closeHandleUnchecked(processHandle);
    }
  }

  /// Closes the owning handle, causing Windows to terminate the Job tree.
  ///
  /// The local handle is cleared before the native close call so finalization
  /// and repeated supervisor disposal cannot close it twice.
  void close() {
    final handle = _handle;
    if (handle == 0) {
      return;
    }
    _handle = 0;
    _finalizer.detach(this);
    if (!_kernel32.closeHandleUnchecked(handle)) {
      throw _kernel32.error('windows_job_object_close_failed');
    }
  }

  /// Test-only process liveness probe used to prove Job descendant cleanup.
  ///
  /// Access denial conservatively counts as alive because this helper must not
  /// claim that a Runtime-owned descendant exited when Windows merely rejected
  /// the inspection request.
  static bool isProcessAlive(int processId) {
    if (!Platform.isWindows || processId <= 0) {
      return false;
    }
    final kernel32 = _Kernel32.instance;
    final processHandle = kernel32.openProcess(
      _processQueryLimitedInformation,
      processId,
    );
    if (processHandle == 0) {
      // Access denial means that a process exists but cannot be queried. That
      // is not expected for the Runtime-owned test child, but it is safer to
      // avoid treating it as a confirmed exit.
      return kernel32.lastError == _errorAccessDenied;
    }

    final exitCode = kernel32.heapAlloc(sizeOf<Uint32>());
    if (exitCode.address == 0) {
      kernel32.closeHandleUnchecked(processHandle);
      throw kernel32.error('windows_job_object_allocate_failed');
    }
    try {
      if (!kernel32.getExitCodeProcess(
        processHandle,
        exitCode.cast<Uint32>(),
      )) {
        throw kernel32.error('windows_job_object_query_process_failed');
      }
      return exitCode.cast<Uint32>().value == _stillActive;
    } finally {
      kernel32.heapFree(exitCode);
      kernel32.closeHandleUnchecked(processHandle);
    }
  }
}

/// Safe representation of a failed Windows Job Object operation.
///
/// The supervisor may project [code] and [message] into Runtime diagnostics;
/// [win32Error] remains a numeric support aid and never includes raw paths or
/// process environment values.
final class WindowsJobObjectException implements Exception {
  const WindowsJobObjectException(this.code, this.message, {this.win32Error});

  /// Stable Runtime-owned diagnostic code for the failed native operation.
  final String code;

  /// Safe generic message that intentionally omits raw native details.
  final String message;

  /// Numeric GetLastError value captured immediately after the native failure.
  final int? win32Error;

  @override
  String toString() => 'WindowsJobObjectException($code): $message';
}

/// Immutable finalizer payload that closes the exact native handle once.
final class _JobHandleFinalizer {
  const _JobHandleFinalizer(this.kernel32, this.handle);

  /// Bound kernel32 calls kept alive until finalizer execution.
  final _Kernel32 kernel32;

  /// Job handle retained only by the finalizer attachment.
  final int handle;
}

///
/// Typed FFI binding for the small kernel32 surface required by Job ownership.
///
/// Keeping all lookups in this private class makes the ABI boundary auditable:
/// no plugin capability or Flutter application code interacts with native
/// process handles directly.
final class _Kernel32 {
  _Kernel32._(DynamicLibrary library)
    : _assignProcessToJobObject = library
          .lookupFunction<
            _AssignProcessToJobObjectNative,
            _AssignProcessToJobObjectDart
          >('AssignProcessToJobObject'),
      _closeHandle = library
          .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle'),
      _createJobObject = library
          .lookupFunction<_CreateJobObjectNative, _CreateJobObjectDart>(
            'CreateJobObjectW',
          ),
      _getExitCodeProcess = library
          .lookupFunction<_GetExitCodeProcessNative, _GetExitCodeProcessDart>(
            'GetExitCodeProcess',
          ),
      _getLastError = library
          .lookupFunction<_GetLastErrorNative, _GetLastErrorDart>(
            'GetLastError',
          ),
      _getProcessHeap = library
          .lookupFunction<_GetProcessHeapNative, _GetProcessHeapDart>(
            'GetProcessHeap',
          ),
      _heapAlloc = library.lookupFunction<_HeapAllocNative, _HeapAllocDart>(
        'HeapAlloc',
      ),
      _heapFree = library.lookupFunction<_HeapFreeNative, _HeapFreeDart>(
        'HeapFree',
      ),
      _openProcess = library
          .lookupFunction<_OpenProcessNative, _OpenProcessDart>('OpenProcess'),
      _setInformationJobObject = library
          .lookupFunction<
            _SetInformationJobObjectNative,
            _SetInformationJobObjectDart
          >('SetInformationJobObject');

  /// Process-wide immutable binding; kernel32 is already loaded on Windows.
  static final _Kernel32 instance = _Kernel32._(
    DynamicLibrary.open('kernel32.dll'),
  );

  /// FFI function pointers match the Win32 signatures declared below.
  final _AssignProcessToJobObjectDart _assignProcessToJobObject;
  final _CloseHandleDart _closeHandle;
  final _CreateJobObjectDart _createJobObject;
  final _GetExitCodeProcessDart _getExitCodeProcess;
  final _GetLastErrorDart _getLastError;
  final _GetProcessHeapDart _getProcessHeap;
  final _HeapAllocDart _heapAlloc;
  final _HeapFreeDart _heapFree;
  final _OpenProcessDart _openProcess;
  final _SetInformationJobObjectDart _setInformationJobObject;

  /// Returns GetLastError immediately after a failed native call.
  int get lastError => _getLastError();

  /// Calls CreateJobObjectW with null security attributes/name for private use.
  int createJobObject(Pointer<Void> attributes, Pointer<Void> name) =>
      _createJobObject(attributes, name);

  /// Returns whether AssignProcessToJobObject accepted the owned child handle.
  bool assignProcessToJobObject(int jobHandle, int processHandle) =>
      _assignProcessToJobObject(jobHandle, processHandle) != 0;

  /// Closes a native handle and returns the raw success flag without throwing.
  bool closeHandleUnchecked(int handle) => _closeHandle(handle) != 0;

  /// Allocates zeroed process-heap storage for an exact FFI structure layout.
  Pointer<Void> heapAlloc(int byteCount) {
    final heap = _getProcessHeap();
    if (heap == 0) {
      throw error('windows_job_object_heap_failed');
    }
    return _heapAlloc(heap, WindowsJobObject._heapZeroMemory, byteCount);
  }

  /// Releases process-heap storage when it was successfully allocated.
  void heapFree(Pointer<Void> pointer) {
    if (pointer.address == 0) {
      return;
    }
    final heap = _getProcessHeap();
    if (heap != 0) {
      _heapFree(heap, 0, pointer);
    }
  }

  /// Opens only the Runtime child with the access flags required by this wrapper.
  int openProcess(int desiredAccess, int processId) =>
      _openProcess(desiredAccess, 0, processId);

  /// Reads the target process exit code into caller-owned native memory.
  bool getExitCodeProcess(int processHandle, Pointer<Uint32> exitCode) =>
      _getExitCodeProcess(processHandle, exitCode) != 0;

  /// Configures a Job Object with a typed native information buffer.
  bool setInformationJobObject(
    int jobHandle,
    int informationClass,
    Pointer<Void> information,
    int informationLength,
  ) =>
      _setInformationJobObject(
        jobHandle,
        informationClass,
        information,
        informationLength,
      ) !=
      0;

  /// Captures the current Win32 error at the point of a failed operation.
  WindowsJobObjectException error(String code) {
    final error = lastError;
    return WindowsJobObjectException(
      code,
      'A Windows Job Object operation failed (Win32 error $error).',
      win32Error: error,
    );
  }
}

///
/// ABI-exact JOBOBJECT_BASIC_LIMIT_INFORMATION layout embedded in the extended
/// limit structure. Field order and native annotations must match Win32; do
/// not simplify this to a Dart object or reorder fields.
final class _JobObjectBasicLimitInformation extends Struct {
  @Int64()
  external int perProcessUserTimeLimit;

  @Int64()
  external int perJobUserTimeLimit;

  /// LimitFlags contains JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE for this Runtime.
  @Uint32()
  external int limitFlags;

  @IntPtr()
  external int minimumWorkingSetSize;

  @IntPtr()
  external int maximumWorkingSetSize;

  @Uint32()
  external int activeProcessLimit;

  @IntPtr()
  external int affinity;

  @Uint32()
  external int priorityClass;

  @Uint32()
  external int schedulingClass;
}

/// ABI-required IO_COUNTERS portion of the extended Job information structure.
///
/// The Runtime does not read these values, but the native structure must retain
/// them to keep subsequent pointer-sized fields at their documented offsets.
final class _IoCounters extends Struct {
  @Uint64()
  external int readOperationCount;

  @Uint64()
  external int writeOperationCount;

  @Uint64()
  external int otherOperationCount;

  @Uint64()
  external int readTransferCount;

  @Uint64()
  external int writeTransferCount;

  @Uint64()
  external int otherTransferCount;
}

/// ABI-exact JOBOBJECT_EXTENDED_LIMIT_INFORMATION passed to kernel32.
final class _JobObjectExtendedLimitInformation extends Struct {
  external _JobObjectBasicLimitInformation basicLimitInformation;
  external _IoCounters ioInfo;

  @IntPtr()
  external int processMemoryLimit;

  @IntPtr()
  external int jobMemoryLimit;

  @IntPtr()
  external int peakProcessMemoryUsed;

  @IntPtr()
  external int peakJobMemoryUsed;
}

/// Shared null pointer used for optional Win32 CreateJobObjectW arguments.
final Pointer<Void> _nullPointer = Pointer<Void>.fromAddress(0);

/// Native/Dart FFI signatures for the audited kernel32 calls above.
typedef _AssignProcessToJobObjectNative = Int32 Function(IntPtr, IntPtr);
typedef _AssignProcessToJobObjectDart = int Function(int, int);
typedef _CloseHandleNative = Int32 Function(IntPtr);
typedef _CloseHandleDart = int Function(int);
typedef _CreateJobObjectNative = IntPtr Function(Pointer<Void>, Pointer<Void>);
typedef _CreateJobObjectDart = int Function(Pointer<Void>, Pointer<Void>);
typedef _GetExitCodeProcessNative = Int32 Function(IntPtr, Pointer<Uint32>);
typedef _GetExitCodeProcessDart = int Function(int, Pointer<Uint32>);
typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastErrorDart = int Function();
typedef _GetProcessHeapNative = IntPtr Function();
typedef _GetProcessHeapDart = int Function();
typedef _HeapAllocNative = Pointer<Void> Function(IntPtr, Uint32, IntPtr);
typedef _HeapAllocDart = Pointer<Void> Function(int, int, int);
typedef _HeapFreeNative = Int32 Function(IntPtr, Uint32, Pointer<Void>);
typedef _HeapFreeDart = int Function(int, int, Pointer<Void>);
typedef _OpenProcessNative = IntPtr Function(Uint32, Int32, Uint32);
typedef _OpenProcessDart = int Function(int, int, int);
typedef _SetInformationJobObjectNative =
    Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32);
typedef _SetInformationJobObjectDart =
    int Function(int, int, Pointer<Void>, int);
