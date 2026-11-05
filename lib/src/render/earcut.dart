// A Dart port of earcut 3.0, the polygon triangulation MapLibre GL uses
// for fills and extrusions: https://github.com/mapbox/earcut
//
// ISC License
//
// Copyright (c) 2024, Mapbox
//
// Permission to use, copy, modify, and/or distribute this software for any
// purpose with or without fee is hereby granted, provided that the above
// copyright notice and this permission notice appear in all copies.
//
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
// WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
// MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
// ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
// WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
// ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
// OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

/// Triangulates one polygon: [data] holds its rings' x,y pairs, the
/// exterior ring first, and [holeIndices] the vertex index each hole
/// starts at. Appends the triangles to [out] as triples of vertex
/// indices into [data], and returns how many indices it appended.
///
/// The algorithm is earcut's, line for line — ear slicing over a doubly
/// linked ring, with a z-order hash for rings past 80 vertices, holes
/// bridged into the exterior ring first, and three fallbacks for
/// degenerate input (filtering collinear points, curing local
/// self-intersections, splitting the ring in two). Like earcut, it
/// never throws on bad geometry: a ring it cannot cut yields fewer
/// triangles, never none for the rest.
int earcut(List<double> data, List<int> holeIndices, List<int> out) {
  final before = out.length;
  final hasHoles = holeIndices.isNotEmpty;
  final outerLen = hasHoles ? holeIndices[0] * 2 : data.length;
  var outerNode = _linkedList(data, 0, outerLen, true);
  if (outerNode == null || identical(outerNode.next, outerNode.prev)) {
    return 0;
  }
  if (hasHoles) outerNode = _eliminateHoles(data, holeIndices, outerNode);

  var minX = 0.0, minY = 0.0, invSize = 0.0;
  // Past 80 vertices, a z-order curve hash speeds up the ear tests.
  if (data.length > 80 * 2) {
    minX = data[0];
    minY = data[1];
    var maxX = minX, maxY = minY;
    for (var i = 2; i < outerLen; i += 2) {
      final x = data[i], y = data[i + 1];
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;
    }
    final size = (maxX - minX) > (maxY - minY) ? maxX - minX : maxY - minY;
    invSize = size != 0 ? 32767 / size : 0;
  }
  _earcutLinked(outerNode, out, minX, minY, invSize, 0);
  return out.length - before;
}

final class _Node {
  /// Vertex index into the coordinate list.
  final int i;
  final double x, y;
  late _Node prev, next;

  /// z-order curve value.
  int z = 0;
  _Node? prevZ, nextZ;

  /// Whether this is a Steiner point (a one-vertex hole).
  bool steiner = false;

  _Node(this.i, this.x, this.y);
}

/// A circular doubly linked list of the ring in [data] from [start] to
/// [end] (coordinate offsets), in the given winding.
_Node? _linkedList(List<double> data, int start, int end, bool clockwise) {
  _Node? last;
  if (clockwise == (_signedArea(data, start, end) > 0)) {
    for (var i = start; i < end; i += 2) {
      last = _insertNode(i >> 1, data[i], data[i + 1], last);
    }
  } else {
    for (var i = end - 2; i >= start; i -= 2) {
      last = _insertNode(i >> 1, data[i], data[i + 1], last);
    }
  }
  if (last != null && _equals(last, last.next)) {
    _removeNode(last);
    last = last.next;
  }
  return last;
}

/// Removes collinear and duplicate points.
_Node? _filterPoints(_Node? start, [_Node? end]) {
  if (start == null) return start;
  end ??= start;
  var p = start;
  bool again;
  do {
    again = false;
    if (!p.steiner && (_equals(p, p.next) || _area(p.prev, p, p.next) == 0)) {
      _removeNode(p);
      p = end = p.prev;
      if (identical(p, p.next)) break;
      again = true;
    } else {
      p = p.next;
    }
  } while (again || !identical(p, end));
  return end;
}

/// The ear slicing loop.
void _earcutLinked(_Node? ear, List<int> triangles, double minX, double minY,
    double invSize, int pass) {
  if (ear == null) return;
  if (pass == 0 && invSize != 0) _indexCurve(ear, minX, minY, invSize);
  var stop = ear;
  var e = ear;
  while (!identical(e.prev, e.next)) {
    final prev = e.prev;
    final next = e.next;
    if (invSize != 0 ? _isEarHashed(e, minX, minY, invSize) : _isEar(e)) {
      triangles
        ..add(prev.i)
        ..add(e.i)
        ..add(next.i);
      _removeNode(e);
      // Skipping the next vertex leaves fewer sliver triangles.
      e = next.next;
      stop = next.next;
      continue;
    }
    e = next;
    // A whole loop without an ear.
    if (identical(e, stop)) {
      if (pass == 0) {
        _earcutLinked(_filterPoints(e), triangles, minX, minY, invSize, 1);
      } else if (pass == 1) {
        final cured = _cureLocalIntersections(_filterPoints(e)!, triangles);
        _earcutLinked(cured, triangles, minX, minY, invSize, 2);
      } else if (pass == 2) {
        _splitEarcut(e, triangles, minX, minY, invSize);
      }
      break;
    }
  }
}

bool _isEar(_Node ear) {
  final a = ear.prev, b = ear, c = ear.next;
  if (_area(a, b, c) >= 0) return false; // reflex
  final ax = a.x, bx = b.x, cx = c.x, ay = a.y, by = b.y, cy = c.y;
  final x0 = _min3(ax, bx, cx), y0 = _min3(ay, by, cy);
  final x1 = _max3(ax, bx, cx), y1 = _max3(ay, by, cy);
  var p = c.next;
  while (!identical(p, a)) {
    if (p.x >= x0 &&
        p.x <= x1 &&
        p.y >= y0 &&
        p.y <= y1 &&
        _pointInTriangleExceptFirst(ax, ay, bx, by, cx, cy, p.x, p.y) &&
        _area(p.prev, p, p.next) >= 0) {
      return false;
    }
    p = p.next;
  }
  return true;
}

bool _isEarHashed(_Node ear, double minX, double minY, double invSize) {
  final a = ear.prev, b = ear, c = ear.next;
  if (_area(a, b, c) >= 0) return false; // reflex
  final ax = a.x, bx = b.x, cx = c.x, ay = a.y, by = b.y, cy = c.y;
  final x0 = _min3(ax, bx, cx), y0 = _min3(ay, by, cy);
  final x1 = _max3(ax, bx, cx), y1 = _max3(ay, by, cy);
  final minZ = _zOrder(x0, y0, minX, minY, invSize);
  final maxZ = _zOrder(x1, y1, minX, minY, invSize);
  var p = ear.prevZ;
  var n = ear.nextZ;

  bool inside(_Node q) =>
      q.x >= x0 &&
      q.x <= x1 &&
      q.y >= y0 &&
      q.y <= y1 &&
      !identical(q, a) &&
      !identical(q, c) &&
      _pointInTriangleExceptFirst(ax, ay, bx, by, cx, cy, q.x, q.y) &&
      _area(q.prev, q, q.next) >= 0;

  // Both directions at once, then whatever is left of either.
  while (p != null && p.z >= minZ && n != null && n.z <= maxZ) {
    if (inside(p)) return false;
    p = p.prevZ;
    if (inside(n)) return false;
    n = n.nextZ;
  }
  while (p != null && p.z >= minZ) {
    if (inside(p)) return false;
    p = p.prevZ;
  }
  while (n != null && n.z <= maxZ) {
    if (inside(n)) return false;
    n = n.nextZ;
  }
  return true;
}

/// Cuts off small local self-intersections.
_Node? _cureLocalIntersections(_Node start, List<int> triangles) {
  var s = start;
  var p = start;
  do {
    final a = p.prev, b = p.next.next;
    if (!_equals(a, b) &&
        _intersects(a, p, p.next, b) &&
        _locallyInside(a, b) &&
        _locallyInside(b, a)) {
      triangles
        ..add(a.i)
        ..add(p.i)
        ..add(b.i);
      _removeNode(p);
      _removeNode(p.next);
      p = s = b;
    }
    p = p.next;
  } while (!identical(p, s));
  return _filterPoints(p);
}

/// Splits the ring in two along a valid diagonal and triangulates both.
void _splitEarcut(_Node start, List<int> triangles, double minX, double minY,
    double invSize) {
  var a = start;
  do {
    var b = a.next.next;
    while (!identical(b, a.prev)) {
      if (a.i != b.i && _isValidDiagonal(a, b)) {
        var c = _splitPolygon(a, b);
        final a2 = _filterPoints(a, a.next);
        c = _filterPoints(c, c.next)!;
        _earcutLinked(a2, triangles, minX, minY, invSize, 0);
        _earcutLinked(c, triangles, minX, minY, invSize, 0);
        return;
      }
      b = b.next;
    }
    a = a.next;
  } while (!identical(a, start));
}

/// Bridges every hole into the exterior ring, leftmost first.
_Node _eliminateHoles(List<double> data, List<int> holeIndices, _Node outer) {
  final queue = <_Node>[];
  final len = holeIndices.length;
  for (var i = 0; i < len; i++) {
    final start = holeIndices[i] * 2;
    final end = i < len - 1 ? holeIndices[i + 1] * 2 : data.length;
    final list = _linkedList(data, start, end, false);
    if (list == null) continue;
    if (identical(list, list.next)) list.steiner = true;
    queue.add(_getLeftmost(list));
  }
  queue.sort(_compareXYSlope);
  var outerNode = outer;
  for (final hole in queue) {
    outerNode = _eliminateHole(hole, outerNode);
  }
  return outerNode;
}

int _compareXYSlope(_Node a, _Node b) {
  var result = a.x - b.x;
  // Holes whose leftmost points meet at a vertex go counter-clockwise,
  // so the bridge is always the point they meet at.
  if (result == 0) {
    result = a.y - b.y;
    if (result == 0) {
      final aSlope = (a.next.y - a.y) / (a.next.x - a.x);
      final bSlope = (b.next.y - b.y) / (b.next.x - b.x);
      result = aSlope - bSlope;
    }
  }
  return result < 0
      ? -1
      : result > 0
          ? 1
          : 0;
}

_Node _eliminateHole(_Node hole, _Node outerNode) {
  final bridge = _findHoleBridge(hole, outerNode);
  if (bridge == null) return outerNode;
  final bridgeReverse = _splitPolygon(bridge, hole);
  _filterPoints(bridgeReverse, bridgeReverse.next);
  return _filterPoints(bridge, bridge.next)!;
}

/// David Eberly's bridge between a hole and the exterior ring.
_Node? _findHoleBridge(_Node hole, _Node outerNode) {
  var p = outerNode;
  final hx = hole.x, hy = hole.y;
  var qx = double.negativeInfinity;
  _Node? m;
  // The segment a ray from the hole's leftmost point to the left hits
  // first; its endpoint with the lesser x is the candidate, unless the
  // ray meets a vertex.
  if (_equals(hole, p)) return p;
  do {
    if (_equals(hole, p.next)) return p.next;
    if (hy <= p.y && hy >= p.next.y && p.next.y != p.y) {
      final x = p.x + (hy - p.y) * (p.next.x - p.x) / (p.next.y - p.y);
      if (x <= hx && x > qx) {
        qx = x;
        m = p.x < p.next.x ? p : p.next;
        if (x == hx) return m; // the hole touches the segment
      }
    }
    p = p.next;
  } while (!identical(p, outerNode));
  if (m == null) return null;

  // A vertex inside the triangle of the hole point, the intersection and
  // the candidate blocks the bridge; take the one at the least angle to
  // the ray instead.
  final stop = m;
  final mx = m.x, my = m.y;
  var tanMin = double.infinity;
  p = m;
  do {
    if (hx >= p.x &&
        p.x >= mx &&
        hx != p.x &&
        _pointInTriangle(
            hy < my ? hx : qx, hy, mx, my, hy < my ? qx : hx, hy, p.x, p.y)) {
      final tan = (hy - p.y).abs() / (hx - p.x);
      if (_locallyInside(p, hole) &&
          (tan < tanMin ||
              (tan == tanMin &&
                  (p.x > m!.x ||
                      (p.x == m.x && _sectorContainsSector(m, p)))))) {
        m = p;
        tanMin = tan;
      }
    }
    p = p.next;
  } while (!identical(p, stop));
  return m;
}

bool _sectorContainsSector(_Node m, _Node p) =>
    _area(m.prev, m, p.prev) < 0 && _area(p.next, m, m.next) < 0;

void _indexCurve(_Node start, double minX, double minY, double invSize) {
  var p = start;
  do {
    if (p.z == 0) p.z = _zOrder(p.x, p.y, minX, minY, invSize);
    p.prevZ = p.prev;
    p.nextZ = p.next;
    p = p.next;
  } while (!identical(p, start));
  p.prevZ!.nextZ = null;
  p.prevZ = null;
  _sortLinked(p);
}

/// Simon Tatham's linked-list merge sort, over the z-order links.
_Node? _sortLinked(_Node? head) {
  var list = head;
  var inSize = 1;
  int numMerges;
  do {
    var p = list;
    list = null;
    _Node? tail;
    numMerges = 0;
    while (p != null) {
      numMerges++;
      _Node? q = p;
      var pSize = 0;
      for (var i = 0; i < inSize; i++) {
        pSize++;
        q = q!.nextZ;
        if (q == null) break;
      }
      var qSize = inSize;
      while (pSize > 0 || (qSize > 0 && q != null)) {
        _Node e;
        if (pSize != 0 && (qSize == 0 || q == null || p!.z <= q.z)) {
          e = p!;
          p = p.nextZ;
          pSize--;
        } else {
          e = q!;
          q = q.nextZ;
          qSize--;
        }
        if (tail != null) {
          tail.nextZ = e;
        } else {
          list = e;
        }
        e.prevZ = tail;
        tail = e;
      }
      p = q;
    }
    tail!.nextZ = null;
    inSize *= 2;
  } while (numMerges > 1);
  return list;
}

/// The z-order of a point, its coordinates scaled into 15 bits.
int _zOrder(double px, double py, double minX, double minY, double invSize) {
  var x = ((px - minX) * invSize).toInt();
  var y = ((py - minY) * invSize).toInt();
  x = (x | (x << 8)) & 0x00FF00FF;
  x = (x | (x << 4)) & 0x0F0F0F0F;
  x = (x | (x << 2)) & 0x33333333;
  x = (x | (x << 1)) & 0x55555555;
  y = (y | (y << 8)) & 0x00FF00FF;
  y = (y | (y << 4)) & 0x0F0F0F0F;
  y = (y | (y << 2)) & 0x33333333;
  y = (y | (y << 1)) & 0x55555555;
  return x | (y << 1);
}

_Node _getLeftmost(_Node start) {
  var p = start;
  var leftmost = start;
  do {
    if (p.x < leftmost.x || (p.x == leftmost.x && p.y < leftmost.y)) {
      leftmost = p;
    }
    p = p.next;
  } while (!identical(p, start));
  return leftmost;
}

bool _pointInTriangle(double ax, double ay, double bx, double by, double cx,
        double cy, double px, double py) =>
    (cx - px) * (ay - py) >= (ax - px) * (cy - py) &&
    (ax - px) * (by - py) >= (bx - px) * (ay - py) &&
    (bx - px) * (cy - py) >= (cx - px) * (by - py);

bool _pointInTriangleExceptFirst(double ax, double ay, double bx, double by,
        double cx, double cy, double px, double py) =>
    !(ax == px && ay == py) && _pointInTriangle(ax, ay, bx, by, cx, cy, px, py);

/// Whether the diagonal a–b lies inside the polygon.
bool _isValidDiagonal(_Node a, _Node b) =>
    a.next.i != b.i &&
    a.prev.i != b.i &&
    !_intersectsPolygon(a, b) &&
    ((_locallyInside(a, b) &&
            _locallyInside(b, a) &&
            _middleInside(a, b) &&
            // No opposite-facing sectors.
            (_area(a.prev, a, b.prev) != 0 || _area(a, b.prev, b) != 0)) ||
        // The special zero-length case.
        (_equals(a, b) &&
            _area(a.prev, a, a.next) > 0 &&
            _area(b.prev, b, b.next) > 0));

/// Twice the signed area of the triangle p, q, r.
double _area(_Node p, _Node q, _Node r) =>
    (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y);

bool _equals(_Node a, _Node b) => a.x == b.x && a.y == b.y;

bool _intersects(_Node p1, _Node q1, _Node p2, _Node q2) {
  final o1 = _sign(_area(p1, q1, p2));
  final o2 = _sign(_area(p1, q1, q2));
  final o3 = _sign(_area(p2, q2, p1));
  final o4 = _sign(_area(p2, q2, q1));
  if (o1 != o2 && o3 != o4) return true;
  if (o1 == 0 && _onSegment(p1, p2, q1)) return true;
  if (o2 == 0 && _onSegment(p1, q2, q1)) return true;
  if (o3 == 0 && _onSegment(p2, p1, q2)) return true;
  if (o4 == 0 && _onSegment(p2, q1, q2)) return true;
  return false;
}

/// For collinear p, q, r: whether q lies on the segment p–r.
bool _onSegment(_Node p, _Node q, _Node r) =>
    q.x <= (p.x > r.x ? p.x : r.x) &&
    q.x >= (p.x < r.x ? p.x : r.x) &&
    q.y <= (p.y > r.y ? p.y : r.y) &&
    q.y >= (p.y < r.y ? p.y : r.y);

int _sign(double v) => v > 0
    ? 1
    : v < 0
        ? -1
        : 0;

bool _intersectsPolygon(_Node a, _Node b) {
  var p = a;
  do {
    if (p.i != a.i &&
        p.next.i != a.i &&
        p.i != b.i &&
        p.next.i != b.i &&
        _intersects(p, p.next, a, b)) {
      return true;
    }
    p = p.next;
  } while (!identical(p, a));
  return false;
}

bool _locallyInside(_Node a, _Node b) => _area(a.prev, a, a.next) < 0
    ? _area(a, b, a.next) >= 0 && _area(a, a.prev, b) >= 0
    : _area(a, b, a.prev) < 0 || _area(a, a.next, b) < 0;

bool _middleInside(_Node a, _Node b) {
  var p = a;
  var inside = false;
  final px = (a.x + b.x) / 2, py = (a.y + b.y) / 2;
  do {
    if (((p.y > py) != (p.next.y > py)) &&
        p.next.y != p.y &&
        (px < (p.next.x - p.x) * (py - p.y) / (p.next.y - p.y) + p.x)) {
      inside = !inside;
    }
    p = p.next;
  } while (!identical(p, a));
  return inside;
}

/// Links a and b with a bridge: splits one ring in two, or merges a hole
/// into the exterior ring. Returns the copy of b.
_Node _splitPolygon(_Node a, _Node b) {
  final a2 = _Node(a.i, a.x, a.y);
  final b2 = _Node(b.i, b.x, b.y);
  final an = a.next;
  final bp = b.prev;
  a.next = b;
  b.prev = a;
  a2.next = an;
  an.prev = a2;
  b2.next = a2;
  a2.prev = b2;
  bp.next = b2;
  b2.prev = bp;
  return b2;
}

_Node _insertNode(int i, double x, double y, _Node? last) {
  final p = _Node(i, x, y);
  if (last == null) {
    p.prev = p;
    p.next = p;
  } else {
    p.next = last.next;
    p.prev = last;
    last.next.prev = p;
    last.next = p;
  }
  return p;
}

void _removeNode(_Node p) {
  p.next.prev = p.prev;
  p.prev.next = p.next;
  final prevZ = p.prevZ, nextZ = p.nextZ;
  if (prevZ != null) prevZ.nextZ = nextZ;
  if (nextZ != null) nextZ.prevZ = prevZ;
}

double _signedArea(List<double> data, int start, int end) {
  var sum = 0.0;
  for (var i = start, j = end - 2; i < end; i += 2) {
    sum += (data[j] - data[i]) * (data[i + 1] + data[j + 1]);
    j = i;
  }
  return sum;
}

double _min3(double a, double b, double c) {
  final ab = a < b ? a : b;
  return ab < c ? ab : c;
}

double _max3(double a, double b, double c) {
  final ab = a > b ? a : b;
  return ab > c ? ab : c;
}
