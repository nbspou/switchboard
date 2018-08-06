class TalkMessage {
  final int id;
  final int request;
  final int response;
  final List<int> data;
  const TalkMessage(this.id, this.request, this.response, this.data);
}
