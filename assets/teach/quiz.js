/* Reusable self-checking quiz component.
   Add <script src="../assets/teach/quiz.js"></script> at the end of a lesson.

   Markup contract:
     <div class="quiz">
       <p class="q">1. Question text?</p>
       <button class="opt" data-correct>Correct answer</button>
       <button class="opt">Wrong answer</button>
       <button class="opt">Wrong answer</button>
       <p class="explain">Feedback shown after answering (explains why).</p>
     </div>

   Behaviour: first click locks the question; correct options turn green,
   wrong picks turn red and the right one is revealed; the explanation and a
   running score appear. Supports many quizzes per page. */
(function () {
  var QUIZ_SELECTOR = ".quiz";

  function countQuestions(quiz) {
    return quiz.querySelectorAll(":scope > .q").length;
  }

  function scoreFor(quiz) {
    var opts = quiz.querySelectorAll(":scope > .opt");
    var correct = 0;
    opts.forEach(function (o) {
      if (o.classList.contains("is-correct") && o.hasAttribute("data-correct")) correct++;
    });
    return correct;
  }

  function markAnswered(quiz) {
    quiz.classList.add("answered");
    var opts = quiz.querySelectorAll(":scope > .opt");
    opts.forEach(function (o) { o.disabled = true; });
  }

  function showExplain(quiz) {
    var explain = quiz.querySelector(":scope > .explain");
    if (explain) explain.classList.add("show");
  }

  function updateScore(quiz) {
    var score = quiz.querySelector(":scope > .score");
    if (!score) return;
    var total = countQuestions(quiz);
    var got = scoreFor(quiz);
    score.textContent = got + " of " + total + " correct";
  }

  function initQuiz(quiz) {
    if (quiz.classList.contains("answered")) return;
    var score = document.createElement("p");
    score.className = "score";
    score.textContent = "Pick an answer above.";
    quiz.appendChild(score);

    var opts = quiz.querySelectorAll(":scope > .opt");
    opts.forEach(function (opt) {
      opt.addEventListener("click", function () {
        if (quiz.classList.contains("answered")) return;

        if (opt.hasAttribute("data-correct")) {
          opt.classList.add("is-correct");
        } else {
          opt.classList.add("is-wrong");
          opts.forEach(function (o) {
            if (o.hasAttribute("data-correct")) o.classList.add("is-correct");
          });
        }
        markAnswered(quiz);
        showExplain(quiz);
        updateScore(quiz);
      });
    });
  }

  document.addEventListener("DOMContentLoaded", function () {
    var quizzes = document.querySelectorAll(QUIZ_SELECTOR);
    quizzes.forEach(initQuiz);
  });
})();
