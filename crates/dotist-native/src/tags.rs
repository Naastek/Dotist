use dotist_core::Task;
use regex::{Captures, Regex};
use serde::Serialize;
use std::{collections::{HashMap, HashSet}, sync::OnceLock};

fn tag_pattern() -> &'static Regex {
    static PATTERN: OnceLock<Regex> = OnceLock::new();
    PATTERN.get_or_init(|| Regex::new(r"(^|\s)#([^\s#]+)").unwrap())
}
fn spacing() -> &'static Regex {
    static SPACING: OnceLock<Regex> = OnceLock::new();
    SPACING.get_or_init(|| Regex::new(r"\s{2,}").unwrap())
}

fn split(title: &str) -> (String, Vec<String>) {
    let mut tags = Vec::new();
    let text = tag_pattern().replace_all(title, |captures: &Captures<'_>| {
        let tag = captures[2].to_owned();
        if !tags.contains(&tag) { tags.push(tag); }
        captures[1].to_owned()
    });
    let cleaned = spacing().replace_all(&text, " ").trim().to_owned();
    (if cleaned.is_empty() { title.to_owned() } else { cleaned }, tags)
}

#[derive(Serialize)]
struct TaskTags { id: String, text: String, tags: Vec<String> }
#[derive(Default, Serialize)]
struct TagCount { tag: String, open: usize, all: usize }
#[derive(Serialize)]
pub struct Description { tasks: Vec<TaskTags>, counts: Vec<TagCount> }

pub fn describe(tasks: &[Task]) -> Description {
    let mut counts: HashMap<String, TagCount> = HashMap::new();
    let tasks = tasks.iter().map(|task| {
        let (text, tags) = split(&task.title);
        for tag in &tags {
            let entry = counts.entry(tag.clone()).or_insert_with(|| TagCount { tag: tag.clone(), ..TagCount::default() });
            entry.all += 1;
            if !task.completed { entry.open += 1; }
        }
        TaskTags { id: task.id.clone(), text, tags }
    }).collect();
    Description { tasks, counts: counts.into_values().collect() }
}

pub fn filter(tasks: &[Task], tag: &str) -> Vec<Task> {
    let mut keep = HashSet::new();
    for task in tasks {
        if split(&task.title).1.iter().any(|value| value == tag) {
            keep.insert(task.id.clone());
            if let Some(parent) = &task.parent_id { keep.insert(parent.clone()); }
        }
    }
    for task in tasks {
        if task.parent_id.as_ref().is_some_and(|parent| keep.contains(parent)) { keep.insert(task.id.clone()); }
    }
    tasks.iter().filter(|task| keep.contains(&task.id)).cloned().collect()
}

pub fn rewrite(title: &str, from: &str, to: Option<&str>) -> String {
    if !split(title).1.iter().any(|tag| tag == from) { return title.to_owned(); }
    let text = tag_pattern().replace_all(title, |captures: &Captures<'_>| {
        let matched = captures.get(0).unwrap();
        let boundary = title[matched.end()..].chars().next().is_none_or(char::is_whitespace);
        if &captures[2] != from || !boundary { return matched.as_str().to_owned(); }
        match to { Some(value) => format!("{}#{value}", &captures[1]), None => captures[1].to_owned() }
    });
    let cleaned = spacing().replace_all(&text, " ").trim().to_owned();
    if cleaned.is_empty() { title.to_owned() } else { cleaned }
}
