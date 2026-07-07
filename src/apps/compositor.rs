use crate::drivers::ps2_mouse::MouseEvent;
use crate::kui::compositor_ipc::{CompositorReply, CompositorRequest};
use crate::kui::window::{FrameRect, WindowError, WindowHandle, WINDOW_MANAGER};

struct DragState {
    handle: WindowHandle,
    grab_x: i32,
    grab_y: i32,
}

pub struct Compositor {
    pid: u32,
    name: &'static str,
    status: crate::proc::ProcessStatus,
    cursor_x: i32,
    cursor_y: i32,
    last_cursor_x: i32,
    last_cursor_y: i32,
    prev_buttons: u8,
    drag: Option<DragState>,
    mouse_bound: bool,
    cache_ready: bool,
}

impl crate::proc::Process for Compositor {
    fn new() -> alloc::boxed::Box<Self> {
        alloc::boxed::Box::new(Self {
            pid: 0,
            name: "Compositor",
            status: crate::proc::ProcessStatus::Running,
            cursor_x: 400,
            cursor_y: 300,
            last_cursor_x: -1,
            last_cursor_y: -1,
            prev_buttons: 0,
            drag: None,
            mouse_bound: false,
            cache_ready: false,
        })
    }

    fn name(&self) -> &'static str {
        self.name
    }

    fn pid(&self) -> u32 {
        self.pid
    }

    fn status(&self) -> crate::proc::ProcessStatus {
        self.status
    }

    fn set_name(&mut self, name: &'static str) {
        self.name = name;
    }

    fn set_pid(&mut self, pid: u32) {
        self.pid = pid;
    }

    fn set_status(&mut self, status: crate::proc::ProcessStatus) {
        self.status = status;
    }

    fn on_init(&self) {
        crate::kui::kdraw::clear_backbuffer(0);
    }

    fn on_tick(&mut self) -> Result<crate::proc::ProcessEvent, crate::proc::ProcessError> {
        if !self.mouse_bound {
            if let Some(mouse_pid) = crate::proc::registry::PROCESS_TABLE
                .lock()
                .iter()
                .find(|entry| entry.name == "PS/2 Mouse")
                .map(|entry| entry.pid)
            {
                crate::proc::create_binding_task(self.pid, mouse_pid);
                self.mouse_bound = true;
                if let Some(fb) = crate::kui::kdraw::GLOBAL_FB.get() {
                    self.cursor_x = fb.0.width as i32 / 2;
                    self.cursor_y = fb.0.height as i32 / 2;
                    WINDOW_MANAGER.lock().mark_cursor_dirty();
                }
            }
        }

        let mut manager = WINDOW_MANAGER.lock();
        if manager.needs_windows_composite() || !self.cache_ready {
            manager.composite_windows();
            self.cache_ready = true;
            self.last_cursor_x = -1;
            self.last_cursor_y = -1;
            manager.mark_cursor_dirty();
        }
        if manager.needs_cursor_composite() {
            manager.composite_cursor(
                self.cursor_x,
                self.cursor_y,
                self.last_cursor_x,
                self.last_cursor_y,
            );
            self.last_cursor_x = self.cursor_x;
            self.last_cursor_y = self.cursor_y;
        }
        drop(manager);

        if crate::kui::kdraw::is_dirty() {
            crate::kui::kdraw::present();
        }
        Ok(crate::proc::ProcessEvent::Yielded)
    }

    fn on_uninit(self: alloc::boxed::Box<Self>) {}

    fn receive(&mut self, data: crate::proc::IpcData) -> Result<(), crate::proc::IpcReceiveError> {
        let crate::proc::IpcData::Payload(payload) = data else {
            return Err(crate::proc::IpcReceiveError::Message("Not expecting any data"));
        };

        if payload.is::<CompositorRequest>() {
            let req = *payload.downcast::<CompositorRequest>().unwrap();
            return self.handle_compositor_request(&req);
        }
        if payload.is::<MouseEvent>() {
            let event = *payload.downcast::<MouseEvent>().unwrap();
            self.handle_mouse(event);
            return Ok(());
        }

        Err(crate::proc::IpcReceiveError::Message("Unknown compositor payload"))
    }

    fn bind(&mut self, _subscriber: u32) {}
}

impl Compositor {
    fn handle_compositor_request(
        &mut self,
        req: &CompositorRequest,
    ) -> Result<(), crate::proc::IpcReceiveError> {
        let mut manager = WINDOW_MANAGER.lock();
        let reply = match req {
            CompositorRequest::CreateWindow {
                owner_pid,
                title,
                x,
                y,
                w,
                h,
            } => {
                let frame = FrameRect {
                    x: *x,
                    y: *y,
                    w: *w,
                    h: *h,
                };
                match manager.create(*owner_pid, title.clone(), frame) {
                    Ok((handle, content)) => CompositorReply::WindowCreated { handle, content },
                    Err(WindowError::InvalidFrame) => {
                        CompositorReply::Error(alloc::string::String::from("invalid frame"))
                    }
                    Err(_) => CompositorReply::Error(alloc::string::String::from("create failed")),
                }
            }
            CompositorRequest::DestroyWindow {
                requester_pid,
                handle,
            } => match manager.destroy(*handle, *requester_pid) {
                Ok(()) => CompositorReply::Ok,
                Err(WindowError::NotFound) => {
                    CompositorReply::Error(alloc::string::String::from("window not found"))
                }
                Err(WindowError::NotOwner) => {
                    CompositorReply::Error(alloc::string::String::from("not owner"))
                }
                Err(_) => CompositorReply::Error(alloc::string::String::from("destroy failed")),
            },
            CompositorRequest::RaiseToTop {
                requester_pid,
                handle,
            } => match manager.raise_to_top(*handle, *requester_pid) {
                Ok(()) => CompositorReply::Ok,
                Err(e) => CompositorReply::Error(alloc::format!("{e:?}")),
            },
            CompositorRequest::LowerToBottom {
                requester_pid,
                handle,
            } => match manager.lower_to_bottom(*handle, *requester_pid) {
                Ok(()) => CompositorReply::Ok,
                Err(e) => CompositorReply::Error(alloc::format!("{e:?}")),
            },
            CompositorRequest::FocusWindow { handle, .. } => {
                manager.focus_window(*handle);
                CompositorReply::Ok
            }
        };
        drop(manager);

        crate::kui::compositor_ipc::set_reply(&reply);
        Ok(())
    }

    fn handle_mouse(&mut self, event: MouseEvent) {
        let fb = crate::kui::kdraw::GLOBAL_FB.get().unwrap().0;
        let max_x = fb.width as i32 - 1;
        let max_y = fb.height as i32 - 1;

        self.cursor_x = (self.cursor_x + event.dx).clamp(0, max_x);
        self.cursor_y = (self.cursor_y + event.dy).clamp(0, max_y);

        let left_now = event.buttons & 0x01 != 0;
        let left_was = self.prev_buttons & 0x01 != 0;
        self.prev_buttons = event.buttons;

        let mut manager = WINDOW_MANAGER.lock();

        if left_now && !left_was {
            if let Some(handle) = manager.window_at(self.cursor_x, self.cursor_y) {
                manager.focus_window(handle);
                if manager.in_title_bar(handle, self.cursor_x, self.cursor_y) {
                    if let Some(frame) = manager.frame_rect(handle) {
                        self.drag = Some(DragState {
                            handle,
                            grab_x: self.cursor_x - frame.x as i32,
                            grab_y: self.cursor_y - frame.y as i32,
                        });
                    }
                }
            } else {
                self.drag = None;
            }
        } else if !left_now && left_was {
            self.drag = None;
        } else if left_now {
            if let Some(drag) = &self.drag {
                let new_x = (self.cursor_x - drag.grab_x).clamp(0, max_x) as u32;
                let new_y = (self.cursor_y - drag.grab_y).clamp(0, max_y) as u32;
                manager.move_window(drag.handle, new_x, new_y);
            }
        }

        manager.mark_cursor_dirty();
    }
}