// Case k: contextual classification across many small conversations, not keyword extraction.
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const out = process.argv[2];
if (!out) throw new Error('usage: node gen-support-tickets.mjs <directory>');
mkdirSync(out, { recursive: true });

// Every ticket mentions the other areas too. The main request, speaker and sequence of events matter;
// neither a product keyword nor a word such as "thanks" determines the requested classification.
const requests = [
  ['The amount on our monthly statement includes two seats that we removed before renewal. I compared the dates on the receipt with our team history, and I need to understand which period those seats cover before our bookkeeper closes the month.',
    'I compared the renewal date with the seat changes. The statement covers the preceding period, and the adjustment appears on the following receipt. I have attached the calculation so your bookkeeper can match each amount to the relevant dates.'],
  ['When I follow the invitation to our shared workspace, the browser takes me back to the page where I enter my address. My colleague can open the same invitation. I need to get into that workspace under my existing account rather than create another profile.',
    'I checked the invitation against the address on your account. The browser was keeping a session for the other workspace. Opening the invitation after ending that session should connect the existing profile; there is no need to register again.'],
  ['The table I download for our weekly review has a different number of entries from the view my colleague sees on screen. We need to take the same set of records into our spreadsheet and retain the dates exactly as the team entered them.',
    'I compared the saved view with the downloaded table. The saved view uses the workspace time zone, while the download initially used the browser setting. I have included the steps for choosing the same date range and preserving the original date column.'],
  ['I make changes on my phone while visiting customers, then open the same records at my desk. The entries from yesterday did not appear on the second device until later. I need to know when it is safe to leave the first device without losing the work.',
    'I checked the queue for the changes made on your phone. They remained on that device while its connection was interrupted. The small status indicator beside the record shows when it has reached the workspace and can be opened elsewhere.'],
  ['Our team has a reminder for the morning handover, but several people received it after the meeting had ended. Their calendars showed the intended time. I need the message to reach the people on that shift without also waking the colleagues who are off duty.',
    'I compared the reminder schedule with the recipients on the shift. The workspace schedule and individual quiet hours both apply. I have included a way to choose the shift group and preview the delivery time for each person before saving it.'],
];

// Twelve different customer accounts of earlier expectations and current experience. Courtesy,
// complaints quoted from colleagues, and an agent's reassuring reply are deliberately mixed in.
const experiences = [
  ['My first note to the team said this would cost us another afternoon.', 'That note was written before I tried the steps you sent; the second attempt went through while we were still on the call.', 'I had kept the old manual checklist nearby, but nobody needed to open it this time.', 'Please pass that on to the people who built this; I have already suggested we use the same approach for the next group.'],
  ['A colleague described the first attempt as a waste of time, which was also what I expected.', 'I repeated the process myself before replying to that message, and got through it without asking anyone to take over.', 'We finished early enough to help the next team, rather than asking them to wait for us.', 'I would choose this setup again; my remaining question is just so I can explain it properly to new starters.'],
  ['I came to this conversation with a page of things I expected to go wrong.', 'Looking back at that page now, I have crossed those items off after doing the work rather than after hearing a promise.', 'The person who usually stays late was able to leave with everyone else yesterday.', 'I wanted to send that experience along, because the change has earned a place in the way we run our day.'],
  ['We used to keep a second system ready in case this one held us up.', 'For the last two handovers that second system has stayed closed, including the shift with the least experienced staff.', 'I heard someone repeat our old complaint in the kitchen and was able to show them what happens now.', 'I am asking about the detail below because I want the rest of the team to use this too, rather than keep working around it.'],
  ['Thanks for staying with the conversation and sending the steps so promptly.', 'I followed those steps before the next handover, but we ended up doing the same work a second time after everyone had left.', 'My colleague said the demonstration looked promising; that is not what happened when we tried to use it for the actual shift.', 'I cannot keep asking people to set aside another evening for this, and I need something beyond another set of instructions.'],
  ['I told the team after the demonstration that we could stop keeping the old checklist.', 'Yesterday I had to ask them to find it again, then sit with each person while they repeated what they had already entered.', 'Your replies have been considerate, and I know the delay is not something you personally chose.', 'Still, I am the one explaining the missed handover to everyone else, and I am running out of reasons to ask them to try again.'],
  ['The first time through was quick enough that I recommended it to another group.', 'Since then we have had to bring an extra person to every handover just to watch whether the work actually gets through.', 'Someone in the other group sent a cheerful note about their trial; our regular shift has not had that experience.', 'If this is how it will continue, I would rather take back my recommendation than put more people through the same afternoon.'],
  ['I appreciate the care in your explanation and have read it with the colleague who handles the next shift.', 'We followed it together and still had to cancel the handover while we reconstructed the missing work.', 'The little practice example was fine, so repeating that example would not tell us anything we have not already seen.', 'Please do not close this on the strength of that practice run; I am not willing to call another interrupted shift an acceptable result.'],
  ['I am collecting the steps for a colleague who starts next week.', 'The last shift followed the old procedure; the next one will use the procedure in your note, so I do not yet have a comparison to report.', 'There are both enthusiastic and unhappy comments in the shared chat, but they refer to other teams and I did not take part in those trials.', 'For now I just need to record which steps belong in our instructions and who can perform them.'],
  ['The message I forwarded earlier was written by someone in a different office.', 'I have not tried their sequence or the alternative you described, and I am not making a recommendation between them.', 'Our next scheduled handover is later in the month, so today is for gathering the details rather than reporting an outcome.', 'Could you confirm which settings our coordinator should write down before that session?'],
  ['I have been asked to put the current procedure into the team handbook.', 'Some older notes describe a difficult afternoon and another describes a smooth trial; neither was a shift I attended.', 'I am leaving those assessments with their authors until we have used the procedure ourselves.', 'The information I need from this ticket is the order of the steps and whether the coordinator needs any extra access.'],
  ['This is a follow-up for our internal record rather than a report of a new incident.', 'We have not reached the part of the schedule where we would use the change, so there is no result for me to compare yet.', 'I have included the earlier correspondence for background, including the praise and the complaint, without adopting either as my own view.', 'Please confirm the applicable procedure so that the record is ready when the next shift starts.'],
];
const openings = [
  'I am writing between two shifts, so I have tried to put the sequence in one place rather than forward several disconnected messages.',
  'Our coordinator asked me to bring the details together. Different people have handled the earlier correspondence, and I want to distinguish their comments from my own experience.',
  'I have gone back through the notes from our last handover before writing this. The dates in the attached record are local to our office.',
  'This message brings together the question we discussed and what happened around it. I will be away from my desk later, but the coordinator can pick up the reply.',
];
const background = [
  'For context, we share one workspace across the morning and evening shifts. People exchange the same records at handover, and a temporary colleague may be using the instructions without anyone from the earlier shift beside them.',
  'I checked the notes with the person who was on duty before me. We are describing the same workspace rather than two test accounts, and the times we wrote down refer to the end of the shift rather than when someone opened the message.',
  'The screenshots in the earlier thread were taken during a practice session. Our regular work includes entries from several people, so I have kept a separate record of what happened during the actual handover to avoid mixing the two.',
  'There is no need to reproduce any private customer records in your reply. An explanation using the example workspace is enough for our handbook, provided that the sequence is the one a coordinator would follow during an ordinary shift.',
  'The person receiving your reply will compare it with the handwritten handover sheet. That sheet records who was present and what they tried, rather than an opinion about which approach the team should use in future.',
  'I can arrange a short call with the next coordinator if a step depends on who is on duty. Please put the instructions in the ticket as well, so the evening shift does not have to rely on what one person remembers from the call.',
  'Our handbook keeps the reason for a step beside the step itself. That has helped new starters decide when to ask a coordinator rather than repeat an action simply because it appears in an older screenshot from another office.',
  'Please use the workspace example from this conversation when referring to dates. The forwarded discussion includes a trial from a different week, and I do not want its timing to be mistaken for the shift described here.',
];
const replies = [
  'Agent reply: Thank you for laying out the sequence and separating your experience from the forwarded comments. I can see why the handover matters to the team. I have kept this reply focused on the request you made rather than assuming the other discussion has the same cause.',
  'Agent reply: I appreciate the detail in your note. I have compared the two sets of instructions and will keep the earlier correspondence attached for reference. The explanation below concerns your workspace; another office may have different settings.',
  'Agent reply: Thanks for checking the dates with your colleague. I have used the actual shift in the record rather than the practice session when reviewing your question. I will leave the ticket available for the next coordinator to follow up.',
];

for (let n = 1; n <= 60; n++) {
  // Permute combinations so filenames do not encode a sentiment or product category.
  const variant = ((n - 1) * 37 + 17) % 60;
  const [request, explanation] = requests[variant % requests.length];
  const experience = experiences[Math.floor(variant / requests.length)];
  const id = String(n).padStart(3, '0');
  const customer = [
    `Customer message: ${openings[n % openings.length]}`,
    `Customer: ${request}`,
    'Customer: The forwarded thread also mentions invoices, workspace invitations, spreadsheet downloads, phone updates and shift reminders. Those are background to the conversation, rather than five separate requests for you to investigate.',
    ...experience.map((text, i) => `Customer: ${text} ${background[(n + i) % background.length]}`),
  ];
  const agent = [
    replies[n % replies.length],
    `Agent: ${explanation}`,
    'Agent: I am glad we can work through the details together. Please keep the earlier notes until the next handover so that we can compare the same sequence if another coordinator needs to follow up. I will not take the tone of a forwarded message as your assessment of the result.',
  ];
  const render = () => [...customer, ...agent]
    .map((text, i) => `K${id}-${String(i + 1).padStart(3, '0')} ${text} eol=KEND${id}-${String(i + 1).padStart(3, '0')}\n`).join('');
  // Add whole prose lines, never truncate either exposure marker or the agent's reply.
  let extra = experience.length;
  while (render().length < 3800) customer.push(`Customer: ${background[(n + extra++) % background.length]}`);
  const text = render();
  if (text.length > 4200) throw new Error(`ticket ${id} exceeds its size budget: ${text.length}`);
  writeFileSync(join(out, `ticket-${id}.txt`), text);
}
