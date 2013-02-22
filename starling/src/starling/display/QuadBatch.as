// =================================================================================================
//
//	Starling Framework
//	Copyright 2012 Gamua OG. All Rights Reserved.
//
//	This program is free software. You can redistribute and/or modify it
//	in accordance with the terms of the accompanying license agreement.
//
// =================================================================================================

package starling.display
{

	import flash.display.BitmapData;
	import flash.display.Graphics;
	import flash.geom.Matrix;
	import flash.geom.Rectangle;
	import flash.utils.getQualifiedClassName;

	import starling.core.RenderSupport;
	import starling.core.Starling;
	import starling.core.starling_internal;
	import starling.filters.FragmentFilter;
	import starling.filters.FragmentFilterMode;
	import starling.textures.Texture;
	import starling.textures.TextureSmoothing;
	import starling.utils.MatrixUtil;
	import starling.utils.VertexData;

	use namespace starling_internal;
    
    /** Optimizes rendering of a number of quads with an identical state.
     * 
     *  <p>The majority of all rendered objects in Starling are quads. In fact, all the default
     *  leaf nodes of Starling are quads (the Image and Quad classes). The rendering of those 
     *  quads can be accelerated by a big factor if all quads with an identical state are sent 
     *  to the GPU in just one call. That's what the QuadBatch class can do.</p>
     *  
     *  <p>The 'flatten' method of the Sprite class uses this class internally to optimize its 
     *  rendering performance. In most situations, it is recommended to stick with flattened
     *  sprites, because they are easier to use. Sometimes, however, it makes sense
     *  to use the QuadBatch class directly: e.g. you can add one quad multiple times to 
     *  a quad batch, whereas you can only add it once to a sprite. Furthermore, this class
     *  does not dispatch <code>ADDED</code> or <code>ADDED_TO_STAGE</code> events when a quad
     *  is added, which makes it more lightweight.</p>
     *  
     *  <p>One QuadBatch object is bound to a specific render state. The first object you add to a 
     *  batch will decide on the QuadBatch's state, that is: its texture, its settings for 
     *  smoothing and blending, and if it's tinted (colored vertices and/or transparency). 
     *  When you reset the batch, it will accept a new state on the next added quad.</p> 
     *  
     *  <p>The class extends DisplayObject, but you can use it even without adding it to the
     *  display tree. Just call the 'renderCustom' method from within another render method,
     *  and pass appropriate values for transformation matrix, alpha and blend mode.</p>
     *
     *  @see Sprite  
     */ 
    public class QuadBatch extends DisplayObject
    {
        private static const QUAD_PROGRAM_NAME:String = "QB_q";

        private var mNumQuads:int;
        private var mSyncRequired:Boolean;

		private var mAlpha:Number;
        private var mTexture:Texture;
        private var mSmoothing:String;
        
        private var mVertexData:VertexData;
		// each quad is four points
        private var mQuadsIndexData:Vector.<int>;

		private var calculatedIndexData:Vector.<int> = new Vector.<int>();
		private var calculatedNgonsCountsData:Vector.<int> = new Vector.<int>();
		private var calculatedVertexData:Vector.<Number> = new Vector.<Number>();
		private var calculatedUVsData:Vector.<Number> = new Vector.<Number>();

        /** Helper objects. */
        private static var sHelperMatrix:Matrix = new Matrix();

        /** Creates a new QuadBatch instance with empty batch data. */
        public function QuadBatch()
        {
            mVertexData = new VertexData(0, true);
            mQuadsIndexData = new Vector.<int>();
            mNumQuads = 0;
			mAlpha = 1;
            mSyncRequired = false;
        }

        /** Creates a duplicate of the QuadBatch object. */
        public function clone():QuadBatch
        {
            var clone:QuadBatch = new QuadBatch();
            clone.mVertexData = mVertexData.clone(0, mNumQuads * 4);
            clone.mQuadsIndexData = mQuadsIndexData.slice(0, mNumQuads * 6);
            clone.mNumQuads = mNumQuads;
//            clone.mTinted = mTinted;
			clone.mAlpha = mAlpha;
            clone.mTexture = mTexture;
            clone.mSmoothing = mSmoothing;
            clone.mSyncRequired = true;
            clone.blendMode = blendMode;
            clone.alpha = alpha;
            return clone;
        }
        
        private function expand(newCapacity:int=-1):void
        {
            var oldCapacity:int = capacity;
            
            if (newCapacity <  0) newCapacity = oldCapacity * 2;
            if (newCapacity == 0) newCapacity = 16;
            if (newCapacity <= oldCapacity) return;
            
            mVertexData.numVertices = newCapacity * 4;
            
            for (var i:int=oldCapacity; i<newCapacity; ++i)
            {
				mQuadsIndexData[int(i*4    )] = i*4;
				mQuadsIndexData[int(i*4 + 1)] = i*4 + 1;
				mQuadsIndexData[int(i*4 + 2)] = i*4 + 3;
				mQuadsIndexData[int(i*4 + 3)] = i*4 + 2;
            }
            
            uploadData();
        }

        /** Uploads the raw data of all batched quads to the vertex buffer. */
        private function syncBuffers():void
        {
			uploadData();
	        mSyncRequired = false;
        }

		private function uploadData():void {
		}

		// returns type of polygons : 0 - triangles, 1 - quads, 2 - ngons
		private function calculatePolygons(projection:Matrix, backWidth:int, backHeight:int, clipRect:Rectangle = null, triangulate:Boolean = true, offsetU:Number = 0, offsetV:Number = 0):int {
			var halfW:Number = backWidth*0.5;
			var halfH:Number = backHeight*0.5;

			var a:Number = projection.a * halfW;
			var b:Number = -projection.b * halfH;
			var c:Number = projection.c * halfW;
			var d:Number = -projection.d * halfH;
			var tx:Number = projection.tx * halfW + halfW;
			var ty:Number = - projection.ty * halfH + halfH;

			var identity:Boolean = (a == 1) && (d == 1) && (projection.b == 0) && (projection.c == 0) && (projection.tx = -1) && (projection.ty == 1);

			var i:int;
			var numVerts:int = numQuads*4;
			var srcVertices:Vector.<Number> = mVertexData.rawData;
			calculatedVertexData.length = numVerts << 1;
			calculatedUVsData.length = numVerts << 1;
			var minX:Number = Number.MAX_VALUE, minY:Number = Number.MAX_VALUE, maxX:Number = -Number.MAX_VALUE, maxY:Number = -Number.MAX_VALUE;
			for (i = 0; i < numVerts; i++) {
				var src:int = i << 3;
				var dst:int = i << 1;
				var x:Number = srcVertices[src];
				var y:Number = srcVertices[int(src + 1)];
				var dX:Number = x;
				var dY:Number = y;
				if (!identity) {
					dX = a * x + c * y + tx;
					dY = b * x + d * y + ty;
				}
				if (dX < minX) minX = dX;
				if (dX > maxX) maxX = dX;
				if (dY < minY) minY = dY;
				if (dY > maxY) maxY = dY;

				calculatedVertexData[dst]          = dX;
				calculatedVertexData[int(dst + 1)] = dY;
				calculatedUVsData[dst] = srcVertices[int(src + 6)] + offsetU;
				calculatedUVsData[int(dst + 1)] = srcVertices[int(src + 7)] + offsetV;
			}
			if (clipRect != null) {
				calculatedIndexData.length = 0;
				calculatedNgonsCountsData.length = 0;
				clipIndices(clipRect, minX, maxX, minY, maxY, triangulate);
				return triangulate ? 0 : 2;
			} else {
				calculatedNgonsCountsData.length = 0;
				var numIndices:int;
				if (triangulate) {
					numIndices = numQuads << 2;
					calculatedIndexData.length = numQuads*6;
					for (i = 0; i < numIndices; i+=4) {
						var index:int = (i >> 2)*6;
						calculatedIndexData[index] = mQuadsIndexData[i];
						calculatedIndexData[int(index + 1)] = mQuadsIndexData[int(i + 1)];
						calculatedIndexData[int(index + 2)] = mQuadsIndexData[int(i + 3)];
						calculatedIndexData[int(index + 3)] = mQuadsIndexData[int(i + 1)];
						calculatedIndexData[int(index + 4)] = mQuadsIndexData[int(i + 2)];
						calculatedIndexData[int(index + 5)] = mQuadsIndexData[int(i + 3)];
					}
					return 0;
				} else {
					numIndices = numQuads << 2;
					calculatedIndexData.length = numIndices;
					for (i = 0; i < numIndices; i++) {
						calculatedIndexData[i] = mQuadsIndexData[i];
					}
					return 1;
				}
			}
			return 0;
		}

		private var points1:Vector.<int> = new Vector.<int>();
		private var points2:Vector.<int> = new Vector.<int>();

		private function clipIndices(rect:Rectangle, minX:Number, maxX:Number, minY:Number, maxY:Number, triangulate:Boolean):void {
			var numIndices:int = numQuads*4;

			var left:Number = rect.x;
			var top:Number = rect.y;
			var right:Number = left + rect.width;
			var bottom:Number = top + rect.height;

			if (maxX <= left || maxY <= top || minX >= right || minY >= bottom) return;

			for (var i:int = 0; i < numIndices; i += 4) {
//			for (var i:int = 0; i < 3; i += 3) {
				var a:int = mQuadsIndexData[i];
				var b:int = mQuadsIndexData[int(i + 1)];
				var c:int = mQuadsIndexData[int(i + 2)];
				points1[0] = a;
				points1[1] = b;
				points1[2] = c;
				points1[3] = mQuadsIndexData[int(i + 3)];
				points1.length = 4;

				var valid:Boolean = true;
				valid &&= clipTriangleX(points2, points1, left, 1);
				valid &&= clipTriangleX(points1, points2, right, -1);
				valid &&= clipTriangleY(points2, points1, top, 1);
				valid &&= clipTriangleY(points1, points2, bottom, -1);
				if (valid) {
					if (triangulate) {
						collectTriangles(points1);
//						collectTriangles(points2);
					} else {
						collectNgons(points1);
					}
				}
			}
		}

		private function collectTriangles(points:Vector.<int>):void {
			var count:int = points.length;
			var a:int, b:int, c:int;
			a = points[0];
			b = points[1];
			for (var j:int = 2; j < count; j++) {
				c = points[j];
				calculatedIndexData.push(a, b, c);
				b = c;
			}
		}

		private function collectNgons(points:Vector.<int>):void {
			var count:int = points.length;
			calculatedNgonsCountsData.push(count);
			for (var i:int = 0; i < count; i++) {
				calculatedIndexData.push(points[i]);
			}
		}

		private function clipTriangleX(destination:Vector.<int>, source:Vector.<int>, plane:Number, direction:int):Boolean {
			destination.length = 0;
			var newNumVerts:int = 0;

			var i:int;
			var t:Number;
			var a:int, b:int;
			var offset1:Number;
			var offset2:Number;
			var ax:Number, ay:Number, bx:Number, by:Number;
			var au:Number, av:Number, bu:Number, bv:Number;

			var numVerts:int = source.length;
			a = source[int(numVerts - 1)] << 1;
			ax = calculatedVertexData[a];
			ay = calculatedVertexData[int(a + 1)];
			au = calculatedUVsData[a];
			av = calculatedUVsData[int(a + 1)];

			var result:Boolean = false;
			for (i = 0; i < numVerts; i++) {
				b = source[i] << 1;
				bx = calculatedVertexData[b];
				by = calculatedVertexData[int(b + 1)];
				bu = calculatedUVsData[b];
				bv = calculatedUVsData[int(b + 1)];

				offset1 = direction*(ax - plane);
				offset2 = direction*(bx - plane);
				if (offset2 >= 0) {
					if (offset1 < 0) {
						t = direction*offset1/(ax - bx);
						destination[newNumVerts] = (addVertex(plane, ay + t * (by - ay), au + t * (bu - au), av + t * (bv - av)) >> 1);
						newNumVerts++;
					}
					destination[newNumVerts] = b >> 1;
					newNumVerts++;
					result = true;
				} else {
					if (offset1 > 0) {
						t = direction*offset2/(bx - ax);
						destination[newNumVerts] = addVertex(plane, by + t * (ay - by), bu + t * (au - bu), bv + t*(av - bv)) >> 1;
						newNumVerts++;
						result = true;
					}
				}
				a = b;
				ax = bx;
				ay = by;
				au = bu;
				av = bv;
			}
			return result;
		}

		private function clipTriangleY(destination:Vector.<int>, source:Vector.<int>, plane:Number, direction:int):Boolean {
			destination.length = 0;
			var newNumVerts:int = 0;

			var i:int;
			var t:Number;
			var a:int, b:int;
			var offset1:Number;
			var offset2:Number;
			var ax:Number, ay:Number, bx:Number, by:Number;
			var au:Number, av:Number, bu:Number, bv:Number;

			var numVerts:int = source.length;
			a = source[int(numVerts - 1)] << 1;
			ax = calculatedVertexData[a];
			ay = calculatedVertexData[int(a + 1)];
			au = calculatedUVsData[a];
			av = calculatedUVsData[int(a + 1)];

			var result:Boolean = false;
			for (i = 0; i < numVerts; i++) {
				b = source[i] << 1;
				bx = calculatedVertexData[b];
				by = calculatedVertexData[int(b + 1)];
				bu = calculatedUVsData[b];
				bv = calculatedUVsData[int(b + 1)];

				offset1 = direction*(ay - plane);
				offset2 = direction*(by - plane);
				if (offset2 >= 0) {
					if (offset1 < 0) {
						t = direction*offset1/(ay - by);
						destination[newNumVerts] = addVertex(ax + t * (bx - ax), plane, au + t * (bu - au), av + t * (bv - av)) >> 1;
						newNumVerts++;
					}
					result = true;
					destination[newNumVerts] = b >> 1;
					newNumVerts++;
				} else {
					if (offset1 > 0) {
						t = direction*offset2/(by - ay);
						destination[newNumVerts] = addVertex(bx + t * (ax - bx), plane, bu + t * (au - bu), bv + t*(av - bv)) >> 1;
						newNumVerts++;
						result = true;
					}
				}
				a = b;
				ax = bx;
				ay = by;
				au = bu;
				av = bv;
			}
			return result;
		}

		private function addVertex(x:Number, y:Number, u:Number, v:Number):int {
			var index:int = calculatedVertexData.length;
			calculatedVertexData[index] = x;
			calculatedVertexData[int(index + 1)] = y;
			calculatedUVsData[index] = u;
			calculatedUVsData[int(index + 1)] = v;
			return index;
		}

        /** Renders the current batch with custom settings for model-view-projection matrix, alpha
         *  and blend mode. This makes it possible to render batches that are not part of the 
         *  display list. */ 
        public function renderCustom(mvpMatrix:Matrix, parentAlpha:Number=1.0,
                                     blendMode:String=null):void
        {

            if (mNumQuads == 0) return;
            if (mSyncRequired) syncBuffers();

			var bitmapData:BitmapData = (mTexture != null) ? mTexture.root.bitmapData : null;
			var offsetU:Number = 0, offsetV:Number = 0;
//			if (bitmapData != null) {
//				offsetU = 0.5/bitmapData.width;
//				offsetV = 1/bitmapData.height;
//			}

			const useDrawTrianglesFP10:Boolean = bitmapData == null;

			var type:int = calculatePolygons(mvpMatrix, Starling.current.renderSupport.backBufferWidth, Starling.current.renderSupport.backBufferHeight, Starling.current.mNativeOverlay.clipRectangle, useDrawTrianglesFP10, offsetU, offsetV);

			if (blendMode == null) blendMode = this.blendMode;
			var canvas:Graphics = (blendMode == BlendMode.NONE) ? Starling.current.mNativeOverlay.nextDraw(1).graphics : Starling.current.mNativeOverlay.nextDraw(mAlpha*parentAlpha, blendMode).graphics;
			if (bitmapData != null) {
				if (useDrawTrianglesFP10) {
					if (calculatedIndexData.length > 0) {
						canvas.beginBitmapFill(bitmapData, null, mTexture.repeat, mSmoothing != TextureSmoothing.NONE);
						canvas.drawTriangles(calculatedVertexData, calculatedIndexData, calculatedUVsData);
					}
				} else {
					if (type == 0) drawTriangles(canvas, bitmapData, mTexture.repeat, mSmoothing != TextureSmoothing.NONE);
					if (type == 1) drawQuads(canvas, bitmapData, mTexture.repeat, mSmoothing != TextureSmoothing.NONE);
					if (type == 2) drawNgons(canvas, bitmapData, mTexture.repeat, mSmoothing != TextureSmoothing.NONE);
				}
			} else {
				if (calculatedIndexData.length > 0) {
					canvas.beginFill(mVertexData.getColor(0));
					canvas.drawTriangles(calculatedVertexData, calculatedIndexData);
				}
			}
        }

		private static const drawMatrix:Matrix = new Matrix();
		private function drawTriangles(graphics:Graphics, bitmap:BitmapData, repeat:Boolean, smoothing:Boolean):void {
			// TODO: use calculated bitmap fill when uv vertices has affine transformation
			var bmdW:int = bitmap.width;
			var bmdH:int = bitmap.height;
			var numIndices:int = calculatedIndexData.length;
			for (var i:int = 0; i < numIndices; i += 3) {
				var a:int = calculatedIndexData[i] << 1;
				var b:int = calculatedIndexData[int(i + 1)] << 1;
				var c:int = calculatedIndexData[int(i + 2)] << 1;
				var ax:Number = calculatedVertexData[a];
				var ay:Number = calculatedVertexData[int(a + 1)];
				var bx:Number = calculatedVertexData[b];
				var by:Number = calculatedVertexData[int(b + 1)];
				var cx:Number = calculatedVertexData[c];
				var cy:Number = calculatedVertexData[int(c + 1)];
				var abx:Number = bx - ax;
				var aby:Number = by - ay;
				var acx:Number = cx - ax;
				var acy:Number = cy - ay;
				var au:Number = calculatedUVsData[a];
				var av:Number = calculatedUVsData[int(a + 1)];
				var abu:Number = (calculatedUVsData[b] - au)*bmdW;
				var abv:Number = (calculatedUVsData[int(b + 1)] - av)*bmdH;
				var acu:Number = (calculatedUVsData[c] - au)*bmdW;
				var acv:Number = (calculatedUVsData[int(c + 1)] - av)*bmdH;
				au *= bmdW;
				av *= bmdH;
				var uvDet:Number = abu*acv - acu*abv;
				if (uvDet > 0.01 || uvDet < -0.01) {
					var m11:Number = acv/uvDet;
					var m12:Number = -acu/uvDet;
					var m21:Number = -abv/uvDet;
					var m22:Number = abu/uvDet;

					drawMatrix.a = abx*m11 + acx*m21;
					drawMatrix.c = abx*m12 + acx*m22;
					drawMatrix.b = aby*m11 + acy*m21;
					drawMatrix.d = aby*m12 + acy*m22;
					drawMatrix.tx = -au*drawMatrix.a - av*drawMatrix.c + ax;
					drawMatrix.ty = -au*drawMatrix.b - av*drawMatrix.d + ay;

//					drawMatrix.a /= bitmap.width;
//					drawMatrix.c /= bitmap.height;
//					drawMatrix.b /= bitmap.width;
//					drawMatrix.d /= bitmap.height;

					graphics.beginBitmapFill(bitmap, drawMatrix, repeat, smoothing);
//					graphics.beginFill(0xFF00, 0.5);
					graphics.moveTo(ax, ay);
					graphics.lineTo(bx, by);
					graphics.lineTo(cx, cy);
				} else {
//					trace("ERROR: uv determinant:", uvDet);
				}
			}
		}

		private function drawQuads(graphics:Graphics, bitmap:BitmapData, repeat:Boolean, smoothing:Boolean):void {
			// TODO: use calculated bitmap fill when uv vertices has affine transformation
			var bmdW:int = bitmap.width;
			var bmdH:int = bitmap.height;
			var numIndices:int = calculatedIndexData.length;
			for (var i:int = 0; i < numIndices; i += 4) {
				var a:int = calculatedIndexData[i] << 1;
				var b:int = calculatedIndexData[int(i + 1)] << 1;
				var c:int = calculatedIndexData[int(i + 2)] << 1;
				var d:int = calculatedIndexData[int(i + 3)] << 1;
				var ax:Number = calculatedVertexData[a];
				var ay:Number = calculatedVertexData[int(a + 1)];
				var bx:Number = calculatedVertexData[b];
				var by:Number = calculatedVertexData[int(b + 1)];
				var cx:Number = calculatedVertexData[c];
				var cy:Number = calculatedVertexData[int(c + 1)];
				var dx:Number = calculatedVertexData[d];
				var dy:Number = calculatedVertexData[int(d + 1)];
				var abx:Number = bx - ax;
				var aby:Number = by - ay;
				var acx:Number = cx - ax;
				var acy:Number = cy - ay;
				var au:Number = calculatedUVsData[a];
				var av:Number = calculatedUVsData[int(a + 1)];
				var abu:Number = (calculatedUVsData[b] - au)*bmdW;
				var abv:Number = (calculatedUVsData[int(b + 1)] - av)*bmdH;
				var acu:Number = (calculatedUVsData[c] - au)*bmdW;
				var acv:Number = (calculatedUVsData[int(c + 1)] - av)*bmdH;
				au *= bmdW;
				av *= bmdH;
				var uvDet:Number = abu*acv - acu*abv;
				if (uvDet > 0.01 || uvDet < -0.01) {
					var m11:Number = acv/uvDet;
					var m12:Number = -acu/uvDet;
					var m21:Number = -abv/uvDet;
					var m22:Number = abu/uvDet;

					drawMatrix.a = abx*m11 + acx*m21;
					drawMatrix.c = abx*m12 + acx*m22;
					drawMatrix.b = aby*m11 + acy*m21;
					drawMatrix.d = aby*m12 + acy*m22;
					drawMatrix.tx = -au*drawMatrix.a - av*drawMatrix.c + ax;
					drawMatrix.ty = -au*drawMatrix.b - av*drawMatrix.d + ay;

//					drawMatrix.a /= bitmap.width;
//					drawMatrix.c /= bitmap.height;
//					drawMatrix.b /= bitmap.width;
//					drawMatrix.d /= bitmap.height;

					graphics.beginBitmapFill(bitmap, drawMatrix, repeat, smoothing);
//					graphics.beginFill(0xFF00, 0.5);
					graphics.moveTo(ax, ay);
					graphics.lineTo(bx, by);
					graphics.lineTo(cx, cy);
					graphics.lineTo(dx, dy);
				} else {
//					trace("ERROR: uv determinant:", uvDet);
				}
			}
		}

		private function drawNgons(graphics:Graphics, bitmap:BitmapData, repeat:Boolean, smoothing:Boolean):void {
			// TODO: use calculated bitmap fill when uv vertices has affine transformation
			var bmdW:int = bitmap.width;
			var bmdH:int = bitmap.height;
			var index:int = 0;
			var numNgons:int = calculatedNgonsCountsData.length;
			for (var i:int = 0; i < numNgons; i++) {
				var count:int = calculatedNgonsCountsData[i];
				var a:int = calculatedIndexData[index] << 1;
				var b:int = calculatedIndexData[int(index + 1)] << 1;
				var c:int = calculatedIndexData[int(index + 2)] << 1;
				var ax:Number = calculatedVertexData[a];
				var ay:Number = calculatedVertexData[int(a + 1)];
				var bx:Number = calculatedVertexData[b];
				var by:Number = calculatedVertexData[int(b + 1)];
				var cx:Number = calculatedVertexData[c];
				var cy:Number = calculatedVertexData[int(c + 1)];
				var abx:Number = bx - ax;
				var aby:Number = by - ay;
				var acx:Number = cx - ax;
				var acy:Number = cy - ay;
				var au:Number = calculatedUVsData[a];
				var av:Number = calculatedUVsData[int(a + 1)];
				var abu:Number = (calculatedUVsData[b] - au)*bmdW;
				var abv:Number = (calculatedUVsData[int(b + 1)] - av)*bmdH;
				var acu:Number = (calculatedUVsData[c] - au)*bmdW;
				var acv:Number = (calculatedUVsData[int(c + 1)] - av)*bmdH;
				au *= bmdW;
				av *= bmdH;
				var uvDet:Number = abu*acv - acu*abv;
				if (uvDet > 0.01 || uvDet < -0.01) {
					var m11:Number = acv/uvDet;
					var m12:Number = -acu/uvDet;
					var m21:Number = -abv/uvDet;
					var m22:Number = abu/uvDet;

					drawMatrix.a = abx*m11 + acx*m21;
					drawMatrix.c = abx*m12 + acx*m22;
					drawMatrix.b = aby*m11 + acy*m21;
					drawMatrix.d = aby*m12 + acy*m22;
					drawMatrix.tx = -au*drawMatrix.a - av*drawMatrix.c + ax;
					drawMatrix.ty = -au*drawMatrix.b - av*drawMatrix.d + ay;

//					drawMatrix.a /= bitmap.width;
//					drawMatrix.c /= bitmap.height;
//					drawMatrix.b /= bitmap.width;
//					drawMatrix.d /= bitmap.height;

					graphics.beginBitmapFill(bitmap, drawMatrix, repeat, smoothing);
//					graphics.beginFill(0xFF00, 0.5);
					graphics.moveTo(ax, ay);
					graphics.lineTo(bx, by);
					graphics.lineTo(cx, cy);
					for (var j:int = 3; j < count; j++) {
						var d:int = calculatedIndexData[int(index + j)] << 1;
						graphics.lineTo(calculatedVertexData[d], calculatedVertexData[int(d + 1)]);
					}
				} else {
//					trace("ERROR: uv determinant:", uvDet);
				}
				index += count;
			}
		}

		/** Resets the batch. The vertex- and index-buffers remain their size, so that they
         *  can be reused quickly. */  
        public function reset():void
        {
            mNumQuads = 0;
            mTexture = null;
            mSmoothing = null;
            mSyncRequired = true;
        }
        
        /** Adds an image to the batch. This method internally calls 'addQuad' with the correct
         *  parameters for 'texture' and 'smoothing'. */ 
        public function addImage(image:Image, parentAlpha:Number=1.0, modelViewMatrix:Matrix=null,
                                 blendMode:String=null):void
        {
            addQuad(image, parentAlpha, image.texture, image.smoothing, modelViewMatrix, blendMode);
        }
        
        /** Adds a quad to the batch. The first quad determines the state of the batch,
         *  i.e. the values for texture, smoothing and blendmode. When you add additional quads,  
         *  make sure they share that state (e.g. with the 'isStageChange' method), or reset
         *  the batch. */ 
        public function addQuad(quad:Quad, parentAlpha:Number=1.0, texture:Texture=null, 
                                smoothing:String=null, modelViewMatrix:Matrix=null, 
                                blendMode:String=null):void
        {
            if (modelViewMatrix == null)
                modelViewMatrix = quad.transformationMatrix;
            
            var tinted:Boolean = texture ? (quad.tinted || parentAlpha != 1.0) : false;
            var alpha:Number = parentAlpha * quad.alpha;
            var vertexID:int = mNumQuads * 4;
            
            if (mNumQuads + 1 > mVertexData.numVertices / 4) expand();
            if (mNumQuads == 0) 
            {
                this.blendMode = blendMode ? blendMode : quad.blendMode;
                mTexture = texture;
//                mTinted = tinted;
				mAlpha = alpha;
                mSmoothing = smoothing;
                mVertexData.setPremultipliedAlpha(
                    texture ? texture.premultipliedAlpha : true, false); 
            }
            
            quad.copyVertexDataTo(mVertexData, vertexID);
            mVertexData.transformVertex(vertexID, modelViewMatrix, 4);
            
//            if (alpha != 1.0)
//                mVertexData.scaleAlpha(vertexID, alpha, 4);

            mSyncRequired = true;
            mNumQuads++;
        }
        
        public function addQuadBatch(quadBatch:QuadBatch, parentAlpha:Number=1.0, 
                                     modelViewMatrix:Matrix=null, blendMode:String=null):void
        {
            if (modelViewMatrix == null)
                modelViewMatrix = quadBatch.transformationMatrix;
            
//            var tinted:Boolean = quadBatch.mTinted || parentAlpha != 1.0;
            var alpha:Number = parentAlpha * quadBatch.alpha;
            var vertexID:int = mNumQuads * 4;
            var numQuads:int = quadBatch.numQuads;
            
            if (mNumQuads + numQuads > capacity) expand(mNumQuads + numQuads);
            if (mNumQuads == 0) 
            {
                this.blendMode = blendMode ? blendMode : quadBatch.blendMode;
                mTexture = quadBatch.mTexture;
//                mTinted = tinted;
				mAlpha = alpha;
                mSmoothing = quadBatch.mSmoothing;
                mVertexData.setPremultipliedAlpha(quadBatch.mVertexData.premultipliedAlpha, false);
            }
            
            quadBatch.mVertexData.copyTo(mVertexData, vertexID, 0, numQuads*4);
            mVertexData.transformVertex(vertexID, modelViewMatrix, numQuads*4);
            
//            if (alpha != 1.0)
//                mVertexData.scaleAlpha(vertexID, alpha, numQuads*4);
            
            mSyncRequired = true;
            mNumQuads += numQuads;
        }
        
        /** Indicates if specific quads can be added to the batch without causing a state change. 
         *  A state change occurs if the quad uses a different base texture, has a different 
         *  'tinted', 'smoothing', 'repeat' or 'blendMode' setting, or if the batch is full
         *  (one batch can contain up to 8192 quads). */
        public function isStateChange(concatenatedAlpha:Number, texture:Texture,
                                      smoothing:String, blendMode:String, numQuads:int=1):Boolean
        {
            if (mNumQuads == 0) return false;
            else if (mNumQuads + numQuads > 8192) return true; // maximum buffer size
            else if (mTexture == null && texture == null) return false;
            else if (mTexture != null && texture != null)
                return mTexture.base != texture.base ||
					   mTexture.root.bitmapData != texture.root.bitmapData ||
                       mTexture.repeat != texture.repeat ||
                       mSmoothing != smoothing ||
//                       mTinted != (tinted || parentAlpha != 1.0) ||
					   mAlpha != concatenatedAlpha ||
                       this.blendMode != blendMode;
            else return true;
        }
        
        // display object methods
        
        /** @inheritDoc */
        public override function getBounds(targetSpace:DisplayObject, resultRect:Rectangle=null):Rectangle
        {
            if (resultRect == null) resultRect = new Rectangle();
            
            var transformationMatrix:Matrix = targetSpace == this ?
                null : getTransformationMatrix(targetSpace, sHelperMatrix);
            
            return mVertexData.getBounds(transformationMatrix, 0, mNumQuads*4, resultRect);
        }
        
        /** @inheritDoc */
        public override function render(support:RenderSupport, parentAlpha:Number):void
        {
            if (mNumQuads)
            {
                support.finishQuadBatch();
                support.raiseDrawCount();
                renderCustom(support.mvpMatrix, alpha * parentAlpha, support.blendMode);
            }
        }
        
        // compilation (for flattened sprites)
        
        /** Analyses an object that is made up exclusively of quads (or other containers)
         *  and creates a vector of QuadBatch objects representing it. This can be
         *  used to render the container very efficiently. The 'flatten'-method of the Sprite 
         *  class uses this method internally. */
        public static function compile(object:DisplayObject, 
                                       quadBatches:Vector.<QuadBatch>):void
        {
            compileObject(object, quadBatches, -1, new Matrix());
        }
        
        private static function compileObject(object:DisplayObject, 
                                              quadBatches:Vector.<QuadBatch>,
                                              quadBatchID:int,
                                              transformationMatrix:Matrix,
                                              alpha:Number=1.0,
                                              blendMode:String=null,
                                              ignoreCurrentFilter:Boolean=false):int
        {
            var i:int;
            var quadBatch:QuadBatch;
            var isRootObject:Boolean = false;
            var objectAlpha:Number = object.alpha;
            
            var container:DisplayObjectContainer = object as DisplayObjectContainer;
            var quad:Quad = object as Quad;
            var batch:QuadBatch = object as QuadBatch;
            var filter:FragmentFilter = object.filter;
            
            if (quadBatchID == -1)
            {
                isRootObject = true;
                quadBatchID = 0;
                objectAlpha = 1.0;
                blendMode = object.blendMode;
                if (quadBatches.length == 0) quadBatches.push(new QuadBatch());
                else quadBatches[0].reset();
            }
            
            if (filter && !ignoreCurrentFilter)
            {
                if (filter.mode == FragmentFilterMode.ABOVE)
                {
                    quadBatchID = compileObject(object, quadBatches, quadBatchID,
                                                transformationMatrix, alpha, blendMode, true);
                }
                
                quadBatchID = compileObject(filter.compile(object), quadBatches, quadBatchID,
                                            transformationMatrix, alpha, blendMode);
                
                if (filter.mode == FragmentFilterMode.BELOW)
                {
                    quadBatchID = compileObject(object, quadBatches, quadBatchID,
                        transformationMatrix, alpha, blendMode, true);
                }
            }
            else if (container)
            {
                var numChildren:int = container.numChildren;
                var childMatrix:Matrix = new Matrix();
                
                for (i=0; i<numChildren; ++i)
                {
                    var child:DisplayObject = container.getChildAt(i);
                    var childVisible:Boolean = child.alpha  != 0.0 && child.visible && 
                                               child.scaleX != 0.0 && child.scaleY != 0.0;
                    if (childVisible)
                    {
                        var childBlendMode:String = child.blendMode == BlendMode.AUTO ?
                                                    blendMode : child.blendMode;
						MatrixUtil.copyFrom(childMatrix, transformationMatrix);
                        RenderSupport.transformMatrixForObject(childMatrix, child);
                        quadBatchID = compileObject(child, quadBatches, quadBatchID, childMatrix, 
                                                    alpha*objectAlpha, childBlendMode);
                    }
                }
            }
            else if (quad || batch)
            {
                var texture:Texture;
                var smoothing:String;
//                var tinted:Boolean;
                var numQuads:int;
                
                if (quad)
                {
                    var image:Image = quad as Image;
                    texture = image ? image.texture : null;
                    smoothing = image ? image.smoothing : null;
//                    tinted = quad.tinted;
                    numQuads = 1;
                }
                else
                {
                    texture = batch.mTexture;
                    smoothing = batch.mSmoothing;
//                    tinted = batch.mTinted;
                    numQuads = batch.mNumQuads;
                }
                
                quadBatch = quadBatches[quadBatchID];

                if (quadBatch.isStateChange(alpha*objectAlpha, texture,
                                            smoothing, blendMode, numQuads))
                {
                    quadBatchID++;
                    if (quadBatches.length <= quadBatchID) quadBatches.push(new QuadBatch());
                    quadBatch = quadBatches[quadBatchID];
                    quadBatch.reset();
                }
                
                if (quad)
                    quadBatch.addQuad(quad, alpha, texture, smoothing, transformationMatrix, blendMode);
                else
                    quadBatch.addQuadBatch(batch, alpha, transformationMatrix, blendMode);
            }
            else
            {
                throw new Error("Unsupported display object: " + getQualifiedClassName(object));
            }
            
            if (isRootObject)
            {
                // remove unused batches
                for (i=quadBatches.length-1; i>quadBatchID; --i)
                    quadBatches.pop().dispose();
            }
            
            return quadBatchID;
        }
        
        // properties
        
        public function get numQuads():int { return mNumQuads; }
//        public function get tinted():Boolean { return mTinted; }
        public function get texture():Texture { return mTexture; }
        public function get smoothing():String { return mSmoothing; }
        
        private function get capacity():int { return mVertexData.numVertices / 4; }

    }
}
