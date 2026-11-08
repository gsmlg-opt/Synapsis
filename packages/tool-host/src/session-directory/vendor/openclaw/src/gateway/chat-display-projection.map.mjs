export function mapChatDisplayMessages   (messages     , project                   )      {
  let projected                 ;
  messages.forEach((message, index) => {
    const next = project(message);
    if (next !== message) {
      projected ??= messages.slice();
      projected[index] = next;
    }
  });
  return projected ?? messages;
}