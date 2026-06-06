/// GET /api/history — keyset 分页活动历史
class HistoryClient {
  // 参数: device, start, end, pageSize, cursorTs, cursorId
  // 返回: { history: [], done, nextTs, nextId }
}

/// POST /api/chat
class ChatClient {}

/// POST /api/heartbeat
class HeartbeatClient {}

/// POST /api/ai-summary
class AiSummaryClient {}

/// GET /api/ai-data
class AiDataClient {}
