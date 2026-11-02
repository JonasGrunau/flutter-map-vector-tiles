import 'label_worker.dart';

/// No isolates for this workload on web: placement passes stay in-frame.
LabelPlacementWorker? createLabelWorker() => null;
