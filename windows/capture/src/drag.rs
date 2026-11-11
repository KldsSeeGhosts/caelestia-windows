//! Image-only screenshot drags. Recordings retain their file-based OLE drag.

use crate::{export, gfx::Gfx};
use std::path::Path;
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::Com::*;
use windows::Win32::System::DataExchange::RegisterClipboardFormatW;
use windows::Win32::System::Ole::*;
use windows::Win32::System::SystemServices::*;
use windows::Win32::UI::Shell::*;
use windows::core::*;

// A plain data object avoids SHCreateDataObject's implicit shell/file formats.
// Only the helper's binary drag-preview formats may be added to image content.
#[implement(IDataObject)]
struct ImageData {
    formats: Vec<u16>,
    context_format: u16,
    media: std::cell::RefCell<Vec<(u16, ImageMedium)>>,
}

enum ImageMedium {
    Bytes(Vec<u8>),
    Stream(IStream),
}

impl ImageMedium {
    fn tymed(&self) -> u32 {
        match self {
            Self::Bytes(_) => TYMED_HGLOBAL.0 as u32,
            Self::Stream(_) => TYMED_ISTREAM.0 as u32,
        }
    }
}

fn image_data(png_format: u16) -> IDataObject {
    let mut formats = export::image_formats(png_format).to_vec();
    formats.push(unsafe { RegisterClipboardFormatW(w!("DragImageBits")) as u16 });
    let context_format = unsafe { RegisterClipboardFormatW(w!("DragContext")) as u16 };
    formats.push(context_format);
    ImageData { formats, context_format, media: Default::default() }.into()
}

fn format_etc(format: u16) -> FORMATETC {
    FORMATETC {
        cfFormat: format,
        dwAspect: DVASPECT_CONTENT.0,
        lindex: -1,
        tymed: TYMED_HGLOBAL.0 as u32,
        ..Default::default()
    }
}

impl ImageData_Impl {
    fn accepts(&self, fmt: &FORMATETC) -> bool {
        self.formats.contains(&fmt.cfFormat)
            && fmt.cfFormat != 0
            && fmt.dwAspect == DVASPECT_CONTENT.0
            && fmt.lindex == -1
            && fmt.tymed & (if fmt.cfFormat == self.context_format { TYMED_ISTREAM } else { TYMED_HGLOBAL }).0 as u32
                != 0
            && fmt.ptd.is_null()
    }
}

impl IDataObject_Impl for ImageData_Impl {
    fn GetData(&self, fmt: *const FORMATETC) -> Result<STGMEDIUM> {
        self.QueryGetData(fmt).ok()?;
        let media = self.media.borrow();
        let medium = &media.iter().find(|(id, _)| *id == unsafe { (*fmt).cfFormat }).unwrap().1;
        let u = match medium {
            ImageMedium::Bytes(bytes) => STGMEDIUM_0 { hGlobal: unsafe { export::global_copy(&[bytes])? } },
            ImageMedium::Stream(stream) => STGMEDIUM_0 { pstm: std::mem::ManuallyDrop::new(Some(stream.clone())) },
        };
        Ok(STGMEDIUM { tymed: medium.tymed(), u, ..Default::default() })
    }
    fn GetDataHere(&self, _: *const FORMATETC, _: *mut STGMEDIUM) -> Result<()> {
        Err(E_NOTIMPL.into())
    }
    fn QueryGetData(&self, fmt: *const FORMATETC) -> HRESULT {
        let Some(fmt) = (unsafe { fmt.as_ref() }) else {
            return E_POINTER;
        };
        if self.accepts(fmt)
            && self.media.borrow().iter().any(|(id, medium)| *id == fmt.cfFormat && fmt.tymed & medium.tymed() != 0)
        {
            S_OK
        } else {
            DV_E_FORMATETC
        }
    }
    fn GetCanonicalFormatEtc(&self, _: *const FORMATETC, out: *mut FORMATETC) -> HRESULT {
        if let Some(out) = unsafe { out.as_mut() } {
            out.ptd = std::ptr::null_mut();
        }
        E_NOTIMPL
    }
    fn SetData(&self, fmt: *const FORMATETC, medium: *const STGMEDIUM, release: BOOL) -> Result<()> {
        let fmt = unsafe { fmt.as_ref() }.ok_or(Error::from(E_POINTER))?;
        let medium = unsafe { medium.as_ref() }.ok_or(Error::from(E_POINTER))?;
        let expected = if fmt.cfFormat == self.context_format { TYMED_ISTREAM } else { TYMED_HGLOBAL };
        if !self.accepts(fmt) || medium.tymed != expected.0 as u32 || fmt.tymed & medium.tymed == 0 {
            return Err(DV_E_FORMATETC.into());
        }
        unsafe {
            use windows::Win32::System::Memory::*;
            let stored = if expected == TYMED_ISTREAM {
                ImageMedium::Stream(medium.u.pstm.as_ref().ok_or(Error::from(E_POINTER))?.clone())
            } else {
                let handle = medium.u.hGlobal;
                let size = GlobalSize(handle);
                let ptr = GlobalLock(handle);
                if ptr.is_null() {
                    return Err(E_OUTOFMEMORY.into());
                }
                let bytes = std::slice::from_raw_parts(ptr.cast::<u8>(), size).to_vec();
                let _ = GlobalUnlock(handle);
                ImageMedium::Bytes(bytes)
            };
            let mut media = self.media.borrow_mut();
            media.retain(|(id, _)| *id != fmt.cfFormat);
            media.push((fmt.cfFormat, stored));
            drop(media);
            if release.as_bool() {
                let mut owned = std::ptr::read(medium);
                ReleaseStgMedium(&mut owned);
            }
        }
        Ok(())
    }
    fn EnumFormatEtc(&self, direction: u32) -> Result<IEnumFORMATETC> {
        if direction != DATADIR_GET.0 as u32 {
            return Err(E_NOTIMPL.into());
        }
        let formats: Vec<_> = self
            .media
            .borrow()
            .iter()
            .map(|(id, medium)| {
                let mut fmt = format_etc(*id);
                fmt.tymed = medium.tymed();
                fmt
            })
            .collect();
        unsafe { SHCreateStdEnumFmtEtc(&formats) }
    }
    fn DAdvise(&self, _: *const FORMATETC, _: u32, _: Ref<IAdviseSink>) -> Result<u32> {
        Err(OLE_E_ADVISENOTSUPPORTED.into())
    }
    fn DUnadvise(&self, _: u32) -> Result<()> {
        Err(OLE_E_ADVISENOTSUPPORTED.into())
    }
    fn EnumDAdvise(&self) -> Result<IEnumSTATDATA> {
        Err(OLE_E_ADVISENOTSUPPORTED.into())
    }
}

#[implement(IDropSource)]
struct Source;

impl IDropSource_Impl for Source_Impl {
    fn QueryContinueDrag(&self, escape: BOOL, keys: MODIFIERKEYS_FLAGS) -> HRESULT {
        if escape.as_bool() {
            DRAGDROP_S_CANCEL
        } else if !keys.contains(MK_LBUTTON) {
            DRAGDROP_S_DROP
        } else {
            S_OK
        }
    }

    fn GiveFeedback(&self, _: DROPEFFECT) -> HRESULT {
        DRAGDROP_S_USEDEFAULTCURSORS
    }
}

unsafe fn set_bytes(data: &IDataObject, format: u16, bytes: &[u8]) -> Result<()> {
    unsafe {
        let fmt = FORMATETC {
            cfFormat: format,
            dwAspect: DVASPECT_CONTENT.0,
            lindex: -1,
            tymed: TYMED_HGLOBAL.0 as u32,
            ..Default::default()
        };
        let mut medium = STGMEDIUM {
            tymed: TYMED_HGLOBAL.0 as u32,
            u: STGMEDIUM_0 { hGlobal: export::global_copy(&[bytes])? },
            ..Default::default()
        };
        if let Err(e) = data.SetData(&fmt, &medium, true) {
            ReleaseStgMedium(&mut medium);
            return Err(e);
        }
        Ok(())
    }
}

fn file_drop(path: &Path) -> Vec<u8> {
    use std::os::windows::ffi::OsStrExt;
    let header = DROPFILES { pFiles: size_of::<DROPFILES>() as u32, fWide: TRUE, ..Default::default() };
    let mut bytes =
        unsafe { std::slice::from_raw_parts(&header as *const _ as *const u8, size_of::<DROPFILES>()).to_vec() };
    for c in path.as_os_str().encode_wide().chain([0, 0]) {
        bytes.extend_from_slice(&c.to_le_bytes());
    }
    bytes
}

unsafe fn file_data(path: &Path) -> Result<IDataObject> {
    unsafe {
        let data = SHCreateDataObject(None, None, None::<&IDataObject>)?;
        set_bytes(&data, CF_HDROP.0, &file_drop(path))?;
        set_bytes(
            &data,
            RegisterClipboardFormatW(w!("Preferred DropEffect")) as u16,
            &DROPEFFECT_COPY.0.to_le_bytes(),
        )?;
        Ok(data)
    }
}

pub fn start(gfx: &Gfx, path: &Path, preview: &export::Image) -> Result<()> {
    let path = std::path::absolute(path).map_err(|e| Error::new(E_FAIL, e.to_string()))?;
    let video = path.extension().is_some_and(|s| s.eq_ignore_ascii_case("mp4"));
    unsafe {
        let data: IDataObject = if video {
            file_data(&path)?
        } else {
            let png_format = RegisterClipboardFormatW(w!("PNG")) as u16;
            if png_format == 0 {
                return Err(Error::from_thread());
            }
            let data = image_data(png_format);
            let png = std::fs::read(&path).map_err(|e| Error::new(E_FAIL, e.to_string()))?;
            let image = export::decode_png_bytes(gfx, &png)?;
            let formats = export::image_formats(png_format);
            set_bytes(&data, formats[0], &png)?;
            set_bytes(&data, formats[1], &export::dib_bytes(&image))?;
            data
        };
        initialize_preview(&data, preview)?;
        let source: IDropSource = Source.into();
        let mut effect = DROPEFFECT_NONE;
        let result = DoDragDrop(&data, &source, DROPEFFECT_COPY, &mut effect);
        result.ok()
    }
}

// Initializes only the bitmap metadata. Does not enter a drag loop or show UI.
fn initialize_preview(data: &IDataObject, preview: &export::Image) -> Result<bool> {
    unsafe {
        let helper: Result<IDragSourceHelper> = CoCreateInstance(&CLSID_DragDropHelper, None, CLSCTX_INPROC_SERVER);
        if let Ok(helper) = helper {
            let bitmap = bitmap(preview)?;
            let info = SHDRAGIMAGE {
                sizeDragImage: SIZE { cx: preview.width as i32, cy: preview.height as i32 },
                ptOffset: POINT { x: preview.width as i32 / 2, y: preview.height as i32 / 2 },
                hbmpDragImage: bitmap,
                crColorKey: COLORREF(0xffffffff),
            };
            if helper.InitializeFromBitmap(&info, data).is_err() {
                let _ = DeleteObject(bitmap.into());
                return Ok(false);
            }
            // On success the helper owns the bitmap.
            return Ok(true);
        }
        Ok(false)
    }
}

pub fn copy_file(path: &Path) -> Result<()> {
    unsafe {
        let data = file_data(path)?;
        OleSetClipboard(&data)?;
        OleFlushClipboard()
    }
}

pub fn bitmap(image: &export::Image) -> Result<HBITMAP> {
    unsafe {
        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: image.width as i32,
                biHeight: -(image.height as i32),
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut bits = std::ptr::null_mut();
        let bitmap = CreateDIBSection(None, &info, DIB_RGB_COLORS, &mut bits, None, 0)?;
        std::ptr::copy_nonoverlapping(image.pixels.as_ptr(), bits.cast(), image.pixels.len());
        Ok(bitmap)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    unsafe fn enumerated(data: &IDataObject) -> Vec<u16> {
        unsafe {
            let list = data.EnumFormatEtc(DATADIR_GET.0 as u32).unwrap();
            let mut item = [FORMATETC::default()];
            let mut result = Vec::new();
            while list.Next(&mut item, None) == S_OK {
                result.push(item[0].cfFormat);
            }
            result
        }
    }

    #[test]
    fn recording_copy_and_drag_keep_file_formats() {
        unsafe {
            OleInitialize(None).unwrap();
            {
                let data = file_data(Path::new("C:\\recording.mp4")).unwrap();
                let effect = RegisterClipboardFormatW(w!("Preferred DropEffect")) as u16;
                let mut formats = enumerated(&data);
                let mut expected = vec![CF_HDROP.0, effect];
                formats.sort_unstable();
                expected.sort_unstable();
                assert_eq!(formats, expected);
                let preview = export::Image { width: 2, height: 2, pixels: vec![255; 16] };
                assert!(initialize_preview(&data, &preview).unwrap());
                expected.extend([
                    RegisterClipboardFormatW(w!("DragImageBits")) as u16,
                    RegisterClipboardFormatW(w!("DragContext")) as u16,
                ]);
                expected.sort_unstable();
                let mut formats = enumerated(&data);
                formats.sort_unstable();
                assert_eq!(formats, expected);
            }
            OleUninitialize();
        }
    }

    #[test]
    fn screenshot_data_object_offers_exactly_images_and_rejects_file_text_urls() {
        unsafe {
            let png = RegisterClipboardFormatW(w!("PNG")) as u16;
            let data = image_data(png);
            let expected = [png, CF_DIB.0];
            assert!(enumerated(&data).is_empty());
            for id in expected {
                set_bytes(&data, id, b"image payload").unwrap();
            }
            assert_eq!(enumerated(&data), expected);
            for id in [
                CF_HDROP.0,
                CF_TEXT.0,
                CF_UNICODETEXT.0,
                CF_OEMTEXT.0,
                RegisterClipboardFormatW(w!("FileName")) as u16,
                RegisterClipboardFormatW(w!("FileNameW")) as u16,
                RegisterClipboardFormatW(w!("FileGroupDescriptor")) as u16,
                RegisterClipboardFormatW(w!("FileGroupDescriptorW")) as u16,
                RegisterClipboardFormatW(w!("FileContents")) as u16,
                RegisterClipboardFormatW(w!("UniformResourceLocator")) as u16,
                RegisterClipboardFormatW(w!("UniformResourceLocatorW")) as u16,
                RegisterClipboardFormatW(w!("text/uri-list")) as u16,
                RegisterClipboardFormatW(w!("Preferred DropEffect")) as u16,
            ] {
                assert!(data.QueryGetData(&format_etc(id)).is_err());
                assert!(set_bytes(&data, id, b"forbidden").is_err());
            }
            assert_eq!(enumerated(&data), expected);
            for id in expected {
                let mut medium = data.GetData(&format_etc(id)).unwrap();
                let ptr = windows::Win32::System::Memory::GlobalLock(medium.u.hGlobal);
                assert_eq!(std::slice::from_raw_parts(ptr.cast::<u8>(), 13), b"image payload");
                let _ = windows::Win32::System::Memory::GlobalUnlock(medium.u.hGlobal);
                ReleaseStgMedium(&mut medium);
            }
        }
    }

    #[test]
    fn screenshot_preview_adds_only_binary_drag_image_metadata() {
        unsafe {
            OleInitialize(None).unwrap();
            {
                let png = RegisterClipboardFormatW(w!("PNG")) as u16;
                let data = image_data(png);
                for id in export::image_formats(png) {
                    set_bytes(&data, id, b"image").unwrap();
                }
                let preview = export::Image { width: 2, height: 2, pixels: vec![255; 16] };
                assert!(initialize_preview(&data, &preview).unwrap());
                let formats = enumerated(&data);
                let bits = RegisterClipboardFormatW(w!("DragImageBits")) as u16;
                assert!(formats.contains(&bits), "drag preview was not retained");
                // The helper stores opaque stream context alongside the bitmap.
                let context = RegisterClipboardFormatW(w!("DragContext")) as u16;
                let mut expected = vec![png, CF_DIB.0, bits, context];
                let mut actual = formats;
                actual.sort_unstable();
                expected.sort_unstable();
                assert_eq!(actual, expected);
                let mut fmt = format_etc(context);
                fmt.tymed = TYMED_ISTREAM.0 as u32;
                let mut medium = data.GetData(&fmt).unwrap();
                assert_eq!(medium.tymed, TYMED_ISTREAM.0 as u32);
                assert!(medium.u.pstm.is_some());
                ReleaseStgMedium(&mut medium);
            }
            OleUninitialize();
        }
    }

    #[test]
    fn hdrop_is_unicode_and_double_terminated() {
        let bytes = file_drop(Path::new("C:\\shots\\日本.png"));
        let header = unsafe { std::ptr::read_unaligned(bytes.as_ptr().cast::<DROPFILES>()) };
        assert_eq!(header.pFiles as usize, size_of::<DROPFILES>());
        assert!(header.fWide.as_bool());
        assert_eq!(&bytes[bytes.len() - 4..], &[0; 4]);
    }

    #[test]
    #[ignore = "native acceptance: OLE shell data object and clipboard format registration"]
    fn shell_data_object_enumerates_and_copies_our_media() {
        unsafe {
            OleInitialize(None).unwrap();
            {
                let data: IDataObject = SHCreateDataObject(None, None, None::<&IDataObject>).unwrap();
                for format in [CF_HDROP.0, CF_DIB.0, RegisterClipboardFormatW(w!("PNG")) as u16] {
                    set_bytes(&data, format, b"test payload").unwrap();
                    let fmt = FORMATETC {
                        cfFormat: format,
                        dwAspect: DVASPECT_CONTENT.0,
                        lindex: -1,
                        tymed: TYMED_HGLOBAL.0 as u32,
                        ..Default::default()
                    };
                    data.QueryGetData(&fmt).ok().unwrap();
                    let mut medium = data.GetData(&fmt).unwrap();
                    let ptr = windows::Win32::System::Memory::GlobalLock(medium.u.hGlobal);
                    assert_eq!(std::slice::from_raw_parts(ptr.cast::<u8>(), 12), b"test payload");
                    let _ = windows::Win32::System::Memory::GlobalUnlock(medium.u.hGlobal);
                    ReleaseStgMedium(&mut medium);
                }
                let formats = data.EnumFormatEtc(DATADIR_GET.0 as u32).unwrap();
                let mut count = 0;
                let mut fmt = [FORMATETC::default()];
                while formats.Next(&mut fmt, None) == S_OK {
                    count += 1;
                }
                assert!(count >= 3);
            }
            OleUninitialize();
        }
    }
}
